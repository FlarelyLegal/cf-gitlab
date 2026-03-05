import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  handleWebhook,
  formatGitLabEmail,
  parseRecipients,
  type Env,
} from "../index";

// ─── Mock helpers ────────────────────────────────────────────────────────────

function mockEnv(overrides: Partial<Env> = {}): Env {
  return {
    GITLAB: {
      fetch: vi.fn(),
    } as unknown as Fetcher,
    ANALYTICS: {
      writeDataPoint: vi.fn(),
    } as unknown as AnalyticsEngineDataset,
    EMAIL: {
      send: vi.fn().mockResolvedValue(undefined),
    } as unknown as SendEmail,
    STORAGE_TOKEN: "test-storage-token",
    WEBHOOK_SECRET: "test-webhook-secret",
    WEBHOOK_RECIPIENT: "test@example.com",
    WEBHOOK_FROM: "noreply@example.com",
    WEBHOOK_FROM_NAME: "Test Worker",
    ...overrides,
  };
}

function webhookRequest(
  body: object,
  options: {
    method?: string;
    token?: string | null;
    event?: string;
  } = {},
): Request {
  const {
    method = "POST",
    token = "test-webhook-secret",
    event = "Push Hook",
  } = options;
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };
  if (token !== null) headers["X-Gitlab-Token"] = token;
  if (event) headers["X-Gitlab-Event"] = event;

  return new Request("https://cdn.example.com/webhook/gitlab", {
    method,
    headers,
    body: method !== "GET" ? JSON.stringify(body) : undefined,
  });
}

const pushPayload = {
  object_kind: "push",
  ref: "refs/heads/main",
  user_name: "Tim",
  project: { name: "test", web_url: "", path_with_namespace: "g/test" },
  total_commits_count: 1,
  commits: [{ message: "test commit", url: "https://example.com/1" }],
};

beforeEach(() => {
  vi.clearAllMocks();
});

// ─── parseRecipients ────────────────────────────────────────────────────────

describe("parseRecipients", () => {
  it("parses a single email", () => {
    expect(parseRecipients("alice@example.com")).toEqual(["alice@example.com"]);
  });

  it("parses comma-separated emails", () => {
    expect(parseRecipients("alice@example.com,bob@example.com")).toEqual([
      "alice@example.com",
      "bob@example.com",
    ]);
  });

  it("trims whitespace around emails", () => {
    expect(parseRecipients("  alice@example.com , bob@example.com  ")).toEqual([
      "alice@example.com",
      "bob@example.com",
    ]);
  });

  it("filters empty entries from trailing commas", () => {
    expect(parseRecipients("alice@example.com,")).toEqual([
      "alice@example.com",
    ]);
  });
});

// ─── handleWebhook auth & routing ───────────────────────────────────────────

describe("handleWebhook", () => {
  it("returns 405 for non-POST methods", async () => {
    const request = new Request("https://cdn.example.com/webhook/gitlab", {
      method: "GET",
    });
    const response = await handleWebhook(request, mockEnv());
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("POST");
  });

  it("returns 401 when X-Gitlab-Token is missing", async () => {
    const request = webhookRequest({}, { token: null });
    const response = await handleWebhook(request, mockEnv());
    expect(response.status).toBe(401);
  });

  it("returns 401 when X-Gitlab-Token is wrong", async () => {
    const request = webhookRequest({}, { token: "wrong-token" });
    const response = await handleWebhook(request, mockEnv());
    expect(response.status).toBe(401);
  });

  it("returns 400 for invalid JSON", async () => {
    const request = new Request("https://cdn.example.com/webhook/gitlab", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Gitlab-Token": "test-webhook-secret",
        "X-Gitlab-Event": "Push Hook",
      },
      body: "not-json{{{",
    });
    const response = await handleWebhook(request, mockEnv());
    expect(response.status).toBe(400);
  });

  it("sends email and returns 200 for valid push webhook", async () => {
    const env = mockEnv();
    const request = webhookRequest(pushPayload, { event: "Push Hook" });
    const response = await handleWebhook(request, env);
    expect(response.status).toBe(200);
    expect(env.EMAIL!.send).toHaveBeenCalledTimes(1);
  });

  it("passes recipients as array to send()", async () => {
    const env = mockEnv();
    const request = webhookRequest(pushPayload, { event: "Push Hook" });
    await handleWebhook(request, env);

    const sendArg = (env.EMAIL!.send as ReturnType<typeof vi.fn>).mock
      .calls[0][0];
    expect(sendArg.to).toEqual(["test@example.com"]);
    expect(sendArg.subject).toContain("[test]");
    expect(sendArg.text).toBeDefined();
  });

  it("sends to multiple recipients from comma-separated env var", async () => {
    const env = mockEnv({
      WEBHOOK_RECIPIENT: "alice@example.com,bob@example.com",
    });
    const request = webhookRequest(pushPayload, { event: "Push Hook" });
    await handleWebhook(request, env);

    const sendArg = (env.EMAIL!.send as ReturnType<typeof vi.fn>).mock
      .calls[0][0];
    expect(sendArg.to).toEqual(["alice@example.com", "bob@example.com"]);
  });

  it("returns 500 when email send fails", async () => {
    const env = mockEnv({
      EMAIL: {
        send: vi.fn().mockRejectedValue(new Error("send failed")),
      } as unknown as SendEmail,
    });
    const request = webhookRequest(pushPayload, { event: "Push Hook" });
    const response = await handleWebhook(request, env);
    expect(response.status).toBe(500);
  });
});

// ─── formatGitLabEmail ──────────────────────────────────────────────────────

describe("formatGitLabEmail", () => {
  const baseProject = {
    name: "my-project",
    web_url: "https://gitlab.example.com/group/my-project",
    path_with_namespace: "group/my-project",
  };

  it("formats Push Hook events", () => {
    const { subject, body } = formatGitLabEmail("Push Hook", {
      ref: "refs/heads/main",
      user_name: "Tim",
      project: baseProject,
      total_commits_count: 2,
      commits: [
        { message: "first commit", url: "https://example.com/1" },
        { message: "second commit", url: "https://example.com/2" },
      ],
    });

    expect(subject).toContain("[my-project]");
    expect(subject).toContain("Tim");
    expect(subject).toContain("main");
    expect(subject).toContain("2 commit(s)");
    expect(body).toContain("first commit");
    expect(body).toContain("second commit");
  });

  it("truncates push commits beyond 5", () => {
    const commits = Array.from({ length: 8 }, (_, i) => ({
      message: `commit ${i + 1}`,
      url: `https://example.com/${i + 1}`,
    }));
    const { body } = formatGitLabEmail("Push Hook", {
      ref: "refs/heads/main",
      user_name: "Tim",
      project: baseProject,
      total_commits_count: 8,
      commits,
    });

    expect(body).toContain("commit 5");
    expect(body).not.toContain("commit 6");
    expect(body).toContain("3 more commit(s)");
  });

  it("formats Tag Push Hook events", () => {
    const { subject, body } = formatGitLabEmail("Tag Push Hook", {
      ref: "refs/tags/v1.0.0",
      user_name: "Tim",
      project: baseProject,
    });

    expect(subject).toContain("v1.0.0");
    expect(body).toContain("Tag v1.0.0");
  });

  it("formats Merge Request Hook events", () => {
    const { subject, body } = formatGitLabEmail("Merge Request Hook", {
      user_name: "Tim",
      project: baseProject,
      object_attributes: {
        title: "Add email notifications",
        url: "https://gitlab.example.com/group/my-project/-/merge_requests/42",
        action: "open",
        iid: 42,
        source_branch: "feature/email",
        target_branch: "main",
      },
    });

    expect(subject).toContain("MR !42");
    expect(subject).toContain("open");
    expect(body).toContain("feature/email");
    expect(body).toContain("main");
  });

  it("formats Pipeline Hook events", () => {
    const { subject, body } = formatGitLabEmail("Pipeline Hook", {
      user_name: "Tim",
      project: baseProject,
      object_attributes: {
        status: "success",
        ref: "main",
      },
      builds: [
        { name: "test", stage: "test", status: "success" },
        { name: "deploy", stage: "deploy", status: "success" },
      ],
    });

    expect(subject).toContain("success");
    expect(subject).toContain("main");
    expect(body).toContain("test/test: success");
    expect(body).toContain("deploy/deploy: success");
  });

  it("formats Issue Hook events", () => {
    const { subject } = formatGitLabEmail("Issue Hook", {
      user_name: "Tim",
      project: baseProject,
      object_attributes: {
        title: "Bug in CDN caching",
        action: "open",
        iid: 7,
        url: "https://gitlab.example.com/group/my-project/-/issues/7",
      },
    });

    expect(subject).toContain("Issue #7");
    expect(subject).toContain("open");
  });

  it("formats Note Hook events", () => {
    const { subject, body } = formatGitLabEmail("Note Hook", {
      user_name: "Tim",
      project: baseProject,
      object_attributes: {
        note: "Looks good to me!",
        noteable_type: "MergeRequest",
        url: "https://gitlab.example.com/group/my-project/-/merge_requests/42#note_1",
      },
    });

    expect(subject).toContain("commented on MergeRequest");
    expect(body).toContain("Looks good to me!");
  });

  it("formats Deployment Hook events", () => {
    const { subject, body } = formatGitLabEmail("Deployment Hook", {
      user_name: "Tim",
      project: baseProject,
      status: "success",
      environment: "production",
    });

    expect(subject).toContain("Deployment success");
    expect(subject).toContain("production");
    expect(body).toContain("production");
  });

  it("formats Release Hook events", () => {
    const { subject, body } = formatGitLabEmail("Release Hook", {
      user_name: "Tim",
      project: baseProject,
      name: "v2.0.0",
      description: "Major release with email support",
      url: "https://gitlab.example.com/group/my-project/-/releases/v2.0.0",
    });

    expect(subject).toContain("Release v2.0.0");
    expect(body).toContain("Major release");
  });

  it("handles unknown event types gracefully", () => {
    const { subject, body } = formatGitLabEmail("Wiki Page Hook", {
      user_name: "Tim",
      project: baseProject,
    });

    expect(subject).toContain("Wiki Page Hook");
    expect(body).toContain("Raw payload");
  });
});
