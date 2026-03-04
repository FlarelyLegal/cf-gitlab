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
 *   STORAGE_TOKEN  → secret (also set in GitLab admin → Repository → Static Objects External Storage)
 *
 * Enable in GitLab:
 *   Admin → Settings → Repository → Static Objects External Storage
 *   URL: https://<CDN_DOMAIN>
 *   Token: (same as STORAGE_TOKEN)
 */

export interface Env {
  GITLAB: Fetcher;
  ANALYTICS: AnalyticsEngineDataset;
  STORAGE_TOKEN: string;
  CACHE_PRIVATE_OBJECTS?: string;
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
          path: new URL(request.url).pathname,
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
