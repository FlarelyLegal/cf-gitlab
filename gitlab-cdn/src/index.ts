/**
 * GitLab CDN — Cloudflare Worker
 *
 * Caching proxy for GitLab static objects (raw files & repository archives).
 * Sits on Cloudflare's edge and caches responses, offloading bandwidth
 * from the self-hosted GitLab instance via Workers VPC tunnel.
 *
 * Connectivity:
 *   Worker → VPC Service binding (GITLAB) → cloudflared tunnel → GitLab origin
 *   Uses HTTP inside the tunnel (QUIC encrypts end-to-end).
 *
 * Configure:
 *   ./generate-wrangler.sh → generates wrangler.jsonc from ../.env
 *   STORAGE_TOKEN   → secret (also set in GitLab admin → Repository → Static Objects External Storage)
 *   WEBHOOK_SECRET  → secret (also set in GitLab webhook config as "Secret token")
 *
 * Enable in GitLab:
 *   Admin → Settings → Repository → Static Objects External Storage
 *   URL: https://<CDN_DOMAIN>
 *   Token: (same as STORAGE_TOKEN)
 *
 * GitLab Webhook:
 *   POST https://<CDN_DOMAIN>/webhook/gitlab
 *   Secret token: (same as WEBHOOK_SECRET)
 */

export interface Env {
  GITLAB: Fetcher;
  ANALYTICS: AnalyticsEngineDataset;
  STORAGE_TOKEN: string;
  CACHE_PRIVATE_OBJECTS?: string;
  /** Email webhook (opt-in via send_email binding + secrets) */
  EMAIL?: SendEmail;
  WEBHOOK_SECRET?: string;
  WEBHOOK_RECIPIENT?: string;
  WEBHOOK_FROM?: string;
  WEBHOOK_FROM_NAME?: string;
}

export const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
  "Access-Control-Allow-Headers": "X-Csrf-Token, X-Requested-With",
};

/** Only proxy raw file downloads and archive downloads */
export const VALID_PATH = /^(.+)(\/raw\/|\/-\/archive\/)/;

export default {
  async fetch(
    request: Request,
    env: Env,
    ctx: ExecutionContext,
  ): Promise<Response> {
    const url = new URL(request.url);

    // ─── Webhook route (opt-in — only active when secrets are configured) ────
    if (url.pathname === "/webhook/gitlab") {
      if (!env.WEBHOOK_SECRET || !env.EMAIL) {
        return new Response(null, { status: 404 });
      }
      return handleWebhook(request, env);
    }

    const startTime = Date.now();
    try {
      const response = await handleRequest(request, env, ctx);
      // Clone to set CORS headers (cached responses are immutable)
      const mutableResponse = new Response(response.body, response);
      mutableResponse.headers.set("Access-Control-Allow-Origin", "*");
      ctx.waitUntil(trackAnalytics(env, request, mutableResponse, startTime));
      return mutableResponse;
    } catch (e) {
      const status = e instanceof HttpError ? e.status : 500;
      console.error(
        JSON.stringify({
          event: "unhandled_error",
          status,
          error: e instanceof Error ? e.message : String(e),
          path: url.pathname,
        }),
      );
      return new Response("An error occurred!", { status });
    }
  },
};

export class HttpError extends Error {
  constructor(
    public status: number,
    message?: string,
  ) {
    super(message);
  }
}

export async function handleRequest(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
): Promise<Response> {
  const url = new URL(request.url);

  // Validate: only allow raw/ and /-/archive/ paths
  if (!VALID_PATH.test(url.pathname)) {
    console.warn(JSON.stringify({ event: "invalid_path", path: url.pathname }));
    return new Response(null, { status: 400 });
  }

  // Handle CORS preflight
  if (request.method === "OPTIONS") {
    return handleOptions(request);
  }

  // Only allow safe methods
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response(null, { status: 405 });
  }

  return proxyToGitLab(request, url, env, ctx);
}

export function handleOptions(request: Request): Response {
  const hasOrigin = request.headers.get("Origin") !== null;
  const hasMethod =
    request.headers.get("Access-Control-Request-Method") !== null;
  const hasHeaders =
    request.headers.get("Access-Control-Request-Headers") !== null;

  if (hasOrigin && hasMethod && hasHeaders) {
    return new Response(null, { headers: CORS_HEADERS });
  }

  return new Response(null, {
    headers: { Allow: "GET, HEAD, OPTIONS" },
  });
}

export async function proxyToGitLab(
  request: Request,
  url: URL,
  env: Env,
  ctx: ExecutionContext,
): Promise<Response> {
  const cache = caches.default;
  const cachePrivate = env.CACHE_PRIVATE_OBJECTS === "true";

  // Build origin URL — HTTP through VPC tunnel (QUIC encrypts end-to-end)
  const originUrl = normalizeQuery(
    new URL(`http://127.0.0.1${url.pathname}${url.search}`),
  );

  // Build proxied request headers
  const headers = new Headers(request.headers);
  headers.set("X-Gitlab-External-Storage-Token", env.STORAGE_TOKEN);

  const staticObjectToken = new URL(request.url).searchParams.get("token");
  if (staticObjectToken) {
    headers.set("X-Gitlab-Static-Object-Token", staticObjectToken);
  }

  // Requests with ?token= are for private/authenticated content — never cache these
  const isPrivate = staticObjectToken !== null;

  const proxiedRequest = new Request(originUrl.toString(), { headers });
  const isConditional = headers.has("If-None-Match");

  // Only check edge cache for public (non-authenticated) requests
  if (!isPrivate) {
    const cachedResponse = await cache.match(proxiedRequest);
    if (cachedResponse && !isConditional) {
      const hit = new Response(cachedResponse.body, cachedResponse);
      hit.headers.set("X-Cache", "HIT");
      console.log(
        JSON.stringify({
          event: "cache_hit",
          path: url.pathname,
          size: parseInt(hit.headers.get("Content-Length") ?? "0", 10),
        }),
      );
      return hit;
    }
  }

  // Fetch from GitLab origin via VPC tunnel
  const originStart = Date.now();
  const originResponse = await env.GITLAB.fetch(proxiedRequest);
  const originLatencyMs = Date.now() - originStart;

  // 304 Not Modified
  if (originResponse.status === 304) {
    const mutable = new Response(originResponse.body, originResponse);
    mutable.headers.set("X-Cache", "REVALIDATED");
    console.log(
      JSON.stringify({
        event: "origin_fetch",
        cache: "REVALIDATED",
        path: url.pathname,
        status: 304,
        originLatencyMs,
      }),
    );
    return mutable;
  }

  // Cache successful responses — only public (no user token) content
  if (originResponse.ok) {
    const response = new Response(originResponse.body, originResponse);
    response.headers.delete("Set-Cookie");

    if (isPrivate) {
      // Private content: pass through, no caching, no public cache headers
      response.headers.set("Cache-Control", "private, no-store");
      response.headers.set("X-Cache", "BYPASS");
      console.log(
        JSON.stringify({
          event: "origin_fetch",
          cache: "BYPASS",
          path: url.pathname,
          status: originResponse.status,
          originLatencyMs,
        }),
      );
    } else {
      // Public content: cache at edge
      response.headers.set(
        "Cache-Control",
        "public, max-age=3600, s-maxage=86400",
      );
      response.headers.set("X-Cache", "MISS");
      console.log(
        JSON.stringify({
          event: "origin_fetch",
          cache: "MISS",
          path: url.pathname,
          status: originResponse.status,
          size: parseInt(response.headers.get("Content-Length") ?? "0", 10),
          originLatencyMs,
        }),
      );
      ctx.waitUntil(cache.put(proxiedRequest, response.clone()));
    }

    return response;
  }

  console.error(
    JSON.stringify({
      event: "origin_error",
      path: url.pathname,
      status: originResponse.status,
      originLatencyMs,
    }),
  );
  return originResponse;
}

export async function trackAnalytics(
  env: Env,
  request: Request,
  response: Response,
  startTime: number,
): Promise<void> {
  const url = new URL(request.url);
  const cacheStatus = response.headers.get("X-Cache") ?? "NONE";
  const contentLength = parseInt(
    response.headers.get("Content-Length") ?? "0",
    10,
  );
  const latencyMs = Date.now() - startTime;
  const pathType = url.pathname.includes("/raw/") ? "raw" : "archive";

  env.ANALYTICS.writeDataPoint({
    indexes: [url.pathname],
    blobs: [
      cacheStatus,
      pathType,
      request.headers.get("CF-Connecting-IP") ?? "",
      url.pathname,
    ],
    doubles: [response.status, contentLength, latencyMs],
  });
}

/** Strip irrelevant query params to maximize cache hits */
export function normalizeQuery(url: URL): URL {
  const searchParams = url.searchParams;
  const clean = new URL(url.toString().split("?")[0]);

  if (url.pathname.includes("/raw/")) {
    const inline = searchParams.get("inline");
    if (inline === "false" || inline === "true") {
      clean.searchParams.set("inline", inline);
    }
  } else if (url.pathname.includes("/-/archive/")) {
    const appendSha = searchParams.get("append_sha");
    const path = searchParams.get("path");

    if (appendSha === "false" || appendSha === "true") {
      clean.searchParams.set("append_sha", appendSha);
    }
    if (path) {
      clean.searchParams.set("path", path);
    }
  }

  return clean;
}

// ─── GitLab Webhook → Email Notification ────────────────────────────────────

/**
 * Parse WEBHOOK_RECIPIENT into an array of email addresses.
 * Supports comma-separated strings: "a@x.com, b@x.com"
 */
export function parseRecipients(raw: string): string[] {
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

/** GitLab event types we handle — everything else gets a generic format */
type GitLabEventType =
  | "Push Hook"
  | "Tag Push Hook"
  | "Merge Request Hook"
  | "Pipeline Hook"
  | "Issue Hook"
  | "Note Hook"
  | "Job Hook"
  | "Deployment Hook"
  | "Release Hook";

/** Minimal shape of the GitLab webhook payload (only fields we use) */
interface GitLabWebhookPayload {
  object_kind?: string;
  event_name?: string;
  ref?: string;
  user_name?: string;
  user_username?: string;
  project?: { name?: string; web_url?: string; path_with_namespace?: string };
  commits?: Array<{
    message?: string;
    url?: string;
    author?: { name?: string };
  }>;
  total_commits_count?: number;
  object_attributes?: {
    title?: string;
    url?: string;
    state?: string;
    action?: string;
    status?: string;
    ref?: string;
    source_branch?: string;
    target_branch?: string;
    iid?: number;
    note?: string;
    noteable_type?: string;
  };
  merge_request?: {
    title?: string;
    url?: string;
    iid?: number;
    source_branch?: string;
    target_branch?: string;
  };
  builds?: Array<{
    name?: string;
    stage?: string;
    status?: string;
  }>;
  tag?: string;
  // Deployment
  status?: string;
  environment?: string;
  deployable_url?: string;
  // Release
  name?: string;
  description?: string;
  url?: string;
}

/**
 * Handle incoming GitLab webhook POST requests.
 * Validates the shared secret, parses the event, and sends an email notification.
 */
export async function handleWebhook(
  request: Request,
  env: Env,
): Promise<Response> {
  if (request.method !== "POST") {
    return new Response(null, { status: 405, headers: { Allow: "POST" } });
  }

  // ── Authenticate via X-Gitlab-Token ──
  const token = request.headers.get("X-Gitlab-Token");
  if (!token || token !== env.WEBHOOK_SECRET) {
    console.warn(
      JSON.stringify({ event: "webhook_auth_failed", hasToken: !!token }),
    );
    return new Response(null, { status: 401 });
  }

  const eventType = request.headers.get("X-Gitlab-Event") ?? "Unknown";

  let payload: GitLabWebhookPayload;
  try {
    payload = (await request.json()) as GitLabWebhookPayload;
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  const { subject, body } = formatGitLabEmail(
    eventType as GitLabEventType,
    payload,
  );
  // Bail if email sending is not fully configured
  if (!env.EMAIL || !env.WEBHOOK_RECIPIENT || !env.WEBHOOK_FROM) {
    return new Response("Email sending not configured", { status: 500 });
  }

  // Recipients must be verified destination addresses in Email Routing.
  // Set as comma-separated list via `wrangler secret put WEBHOOK_RECIPIENT`
  const recipients = parseRecipients(env.WEBHOOK_RECIPIENT);
  const fromAddr = env.WEBHOOK_FROM;
  const fromName = env.WEBHOOK_FROM_NAME ?? "GitLab Webhook";

  console.log(
    JSON.stringify({
      event: "webhook_received",
      gitlabEvent: eventType,
      project: payload.project?.path_with_namespace,
      user: payload.user_name ?? payload.user_username,
      subject,
      recipients,
    }),
  );

  try {
    await env.EMAIL.send({
      from: `${fromName} <${fromAddr}>`,
      to: recipients,
      subject,
      text: body,
    });

    console.log(
      JSON.stringify({
        event: "webhook_email_sent",
        gitlabEvent: eventType,
        project: payload.project?.path_with_namespace,
        subject,
        recipients,
      }),
    );
    return new Response("OK", { status: 200 });
  } catch (e) {
    console.error(
      JSON.stringify({
        event: "webhook_email_error",
        error: e instanceof Error ? e.message : String(e),
        gitlabEvent: eventType,
        project: payload.project?.path_with_namespace,
        subject,
        recipients,
      }),
    );
    return new Response("Failed to send email", { status: 500 });
  }
}

/**
 * Build a human-readable subject + plaintext body from a GitLab event payload.
 */
export function formatGitLabEmail(
  eventType: GitLabEventType | string,
  payload: GitLabWebhookPayload,
): { subject: string; body: string } {
  const project = payload.project?.name ?? "Unknown project";
  const projectUrl = payload.project?.web_url ?? "";
  const user = payload.user_name ?? payload.user_username ?? "Someone";

  switch (eventType) {
    case "Push Hook": {
      const branch = payload.ref?.replace("refs/heads/", "") ?? "unknown";
      const count = payload.total_commits_count ?? 0;
      const commitLines =
        payload.commits
          ?.slice(0, 5)
          .map(
            (c) =>
              `  - ${c.message?.split("\n")[0] ?? "(no message)"}\n    ${c.url ?? ""}`,
          )
          .join("\n") ?? "";
      const truncated =
        count > 5 ? `\n  ... and ${count - 5} more commit(s)` : "";

      return {
        subject: `[${project}] ${user} pushed ${count} commit(s) to ${branch}`,
        body: [
          `Push to ${branch} by ${user}`,
          `Project: ${project} (${projectUrl})`,
          `Commits (${count}):`,
          commitLines,
          truncated,
        ]
          .filter(Boolean)
          .join("\n"),
      };
    }

    case "Tag Push Hook": {
      const tag =
        payload.ref?.replace("refs/tags/", "") ?? payload.tag ?? "unknown";
      return {
        subject: `[${project}] ${user} pushed tag ${tag}`,
        body: [
          `Tag ${tag} pushed by ${user}`,
          `Project: ${project} (${projectUrl})`,
        ].join("\n"),
      };
    }

    case "Merge Request Hook": {
      const mr = payload.object_attributes;
      const action = mr?.action ?? mr?.state ?? "updated";
      const title = mr?.title ?? "(untitled)";
      const source = mr?.source_branch ?? "?";
      const target = mr?.target_branch ?? "?";
      return {
        subject: `[${project}] MR !${mr?.iid ?? "?"} ${action}: ${title}`,
        body: [
          `Merge Request ${action} by ${user}`,
          `Title: ${title}`,
          `${source} → ${target}`,
          mr?.url ?? "",
          `Project: ${project} (${projectUrl})`,
        ]
          .filter(Boolean)
          .join("\n"),
      };
    }

    case "Pipeline Hook": {
      const status = payload.object_attributes?.status ?? "unknown";
      const ref =
        payload.object_attributes?.ref ??
        payload.ref?.replace("refs/heads/", "") ??
        "?";
      const stages =
        payload.builds
          ?.map((b) => `  - ${b.stage}/${b.name}: ${b.status}`)
          .join("\n") ?? "";
      return {
        subject: `[${project}] Pipeline ${status} on ${ref}`,
        body: [
          `Pipeline ${status} on ${ref}`,
          `Triggered by ${user}`,
          stages ? `Jobs:\n${stages}` : "",
          `Project: ${project} (${projectUrl})`,
        ]
          .filter(Boolean)
          .join("\n"),
      };
    }

    case "Issue Hook": {
      const issue = payload.object_attributes;
      const action = issue?.action ?? issue?.state ?? "updated";
      const title = issue?.title ?? "(untitled)";
      return {
        subject: `[${project}] Issue #${issue?.iid ?? "?"} ${action}: ${title}`,
        body: [
          `Issue ${action} by ${user}`,
          `Title: ${title}`,
          issue?.url ?? "",
          `Project: ${project} (${projectUrl})`,
        ]
          .filter(Boolean)
          .join("\n"),
      };
    }

    case "Note Hook": {
      const note = payload.object_attributes;
      const on = note?.noteable_type ?? "item";
      const snippet =
        note?.note && note.note.length > 200
          ? note.note.slice(0, 200) + "..."
          : (note?.note ?? "");
      return {
        subject: `[${project}] ${user} commented on ${on}`,
        body: [
          `${user} commented on ${on}`,
          snippet ? `> ${snippet}` : "",
          note?.url ?? "",
          `Project: ${project} (${projectUrl})`,
        ]
          .filter(Boolean)
          .join("\n"),
      };
    }

    case "Job Hook": {
      const status = payload.object_attributes?.status ?? "unknown";
      const name = payload.object_attributes?.title ?? "job";
      const ref =
        payload.ref?.replace("refs/heads/", "") ??
        payload.object_attributes?.ref ??
        "?";
      return {
        subject: `[${project}] Job "${name}" ${status} on ${ref}`,
        body: [
          `Job "${name}" ${status} on ${ref}`,
          `Project: ${project} (${projectUrl})`,
        ].join("\n"),
      };
    }

    case "Deployment Hook": {
      const status = payload.status ?? "unknown";
      const environment = payload.environment ?? "unknown";
      return {
        subject: `[${project}] Deployment ${status} to ${environment}`,
        body: [
          `Deployment ${status} to ${environment} by ${user}`,
          payload.deployable_url ?? "",
          `Project: ${project} (${projectUrl})`,
        ]
          .filter(Boolean)
          .join("\n"),
      };
    }

    case "Release Hook": {
      const name = payload.name ?? payload.tag ?? "unknown";
      return {
        subject: `[${project}] Release ${name}`,
        body: [
          `Release ${name} by ${user}`,
          payload.description
            ? payload.description.length > 500
              ? payload.description.slice(0, 500) + "..."
              : payload.description
            : "",
          payload.url ?? "",
          `Project: ${project} (${projectUrl})`,
        ]
          .filter(Boolean)
          .join("\n"),
      };
    }

    default: {
      return {
        subject: `[${project}] GitLab event: ${eventType}`,
        body: [
          `Event: ${eventType}`,
          `Triggered by ${user}`,
          `Project: ${project} (${projectUrl})`,
          "",
          "Raw payload (truncated):",
          JSON.stringify(payload, null, 2).slice(0, 1000),
        ].join("\n"),
      };
    }
  }
}
