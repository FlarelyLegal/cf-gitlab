import { describe, it, expect, vi, beforeEach } from "vitest";
import { handleRequest, proxyToGitLab, type Env } from "../index";

// ─── Mock helpers ────────────────────────────────────────────────────────────

function mockEnv(overrides: Partial<Env> = {}): Env {
  return {
    GITLAB: {
      fetch: vi.fn().mockResolvedValue(
        new Response("origin body", {
          status: 200,
          headers: { "Content-Length": "11" },
        }),
      ),
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

function mockCtx(): ExecutionContext {
  return {
    waitUntil: vi.fn(),
    passThroughOnException: vi.fn(),
  } as unknown as ExecutionContext;
}

// Mock the Cache API globally
const mockCache = {
  match: vi.fn().mockResolvedValue(undefined),
  put: vi.fn().mockResolvedValue(undefined),
};

vi.stubGlobal("caches", {
  default: mockCache,
});

beforeEach(() => {
  vi.clearAllMocks();
  mockCache.match.mockResolvedValue(undefined);
  mockCache.put.mockResolvedValue(undefined);
});

// ─── handleRequest routing ──────────────────────────────────────────────────

describe("handleRequest", () => {
  it("returns 400 for invalid paths", async () => {
    const request = new Request(
      "https://cdn.example.com/group/project/-/blob/main/file.txt",
    );
    const response = await handleRequest(request, mockEnv(), mockCtx());
    expect(response.status).toBe(400);
  });

  it("returns 405 for POST requests", async () => {
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
      {
        method: "POST",
      },
    );
    const response = await handleRequest(request, mockEnv(), mockCtx());
    expect(response.status).toBe(405);
  });

  it("returns 405 for PUT requests", async () => {
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
      {
        method: "PUT",
      },
    );
    const response = await handleRequest(request, mockEnv(), mockCtx());
    expect(response.status).toBe(405);
  });

  it("returns 405 for DELETE requests", async () => {
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
      {
        method: "DELETE",
      },
    );
    const response = await handleRequest(request, mockEnv(), mockCtx());
    expect(response.status).toBe(405);
  });

  it("handles OPTIONS preflight for valid path", async () => {
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
      {
        method: "OPTIONS",
        headers: {
          Origin: "https://example.com",
          "Access-Control-Request-Method": "GET",
          "Access-Control-Request-Headers": "X-Csrf-Token",
        },
      },
    );
    const response = await handleRequest(request, mockEnv(), mockCtx());
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe("*");
  });

  it("proxies GET requests for valid raw paths", async () => {
    const env = mockEnv();
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
    );
    const response = await handleRequest(request, env, mockCtx());
    expect(response.status).toBe(200);
    expect(env.GITLAB.fetch).toHaveBeenCalled();
  });

  it("proxies HEAD requests for valid raw paths", async () => {
    const env = mockEnv();
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
      {
        method: "HEAD",
      },
    );
    const response = await handleRequest(request, env, mockCtx());
    expect(response.status).toBe(200);
  });

  it("proxies GET requests for valid archive paths", async () => {
    const env = mockEnv();
    const request = new Request(
      "https://cdn.example.com/group/project/-/archive/main/project-main.tar.gz",
    );
    const response = await handleRequest(request, env, mockCtx());
    expect(response.status).toBe(200);
    expect(env.GITLAB.fetch).toHaveBeenCalled();
  });
});

// ─── proxyToGitLab caching behavior ─────────────────────────────────────────

describe("proxyToGitLab", () => {
  it("sets X-Cache: MISS on public cache miss", async () => {
    const env = mockEnv();
    const ctx = mockCtx();
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
    );
    const url = new URL(request.url);

    const response = await proxyToGitLab(request, url, env, ctx);
    expect(response.headers.get("X-Cache")).toBe("MISS");
    expect(response.headers.get("Cache-Control")).toBe(
      "public, max-age=3600, s-maxage=86400",
    );
  });

  it("caches public responses at the edge", async () => {
    const env = mockEnv();
    const ctx = mockCtx();
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
    );
    const url = new URL(request.url);

    await proxyToGitLab(request, url, env, ctx);
    expect(ctx.waitUntil).toHaveBeenCalled();
    expect(mockCache.put).toHaveBeenCalled();
  });

  it("returns X-Cache: HIT when cache has a match", async () => {
    const cachedResponse = new Response("cached body", {
      status: 200,
      headers: { "Content-Length": "11" },
    });
    mockCache.match.mockResolvedValue(cachedResponse);

    const env = mockEnv();
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
    );
    const url = new URL(request.url);

    const response = await proxyToGitLab(request, url, env, mockCtx());
    expect(response.headers.get("X-Cache")).toBe("HIT");
    // Should NOT have fetched from origin
    expect(env.GITLAB.fetch).not.toHaveBeenCalled();
  });

  it("sets X-Cache: BYPASS for private (token) requests", async () => {
    const env = mockEnv();
    const ctx = mockCtx();
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt?token=user-token",
    );
    const url = new URL(request.url);

    const response = await proxyToGitLab(request, url, env, ctx);
    expect(response.headers.get("X-Cache")).toBe("BYPASS");
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("does not cache private requests", async () => {
    const env = mockEnv();
    const ctx = mockCtx();
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt?token=user-token",
    );
    const url = new URL(request.url);

    await proxyToGitLab(request, url, env, ctx);
    expect(mockCache.put).not.toHaveBeenCalled();
  });

  it("does not check cache for private requests", async () => {
    const env = mockEnv();
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt?token=user-token",
    );
    const url = new URL(request.url);

    await proxyToGitLab(request, url, env, mockCtx());
    expect(mockCache.match).not.toHaveBeenCalled();
  });

  it("sets X-Gitlab-External-Storage-Token header on origin request", async () => {
    const env = mockEnv();
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
    );
    const url = new URL(request.url);

    await proxyToGitLab(request, url, env, mockCtx());

    const fetchCall = (env.GITLAB.fetch as ReturnType<typeof vi.fn>).mock
      .calls[0][0] as Request;
    expect(fetchCall.headers.get("X-Gitlab-External-Storage-Token")).toBe(
      "test-storage-token",
    );
  });

  it("sets X-Gitlab-Static-Object-Token header for token requests", async () => {
    const env = mockEnv();
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt?token=user-token-123",
    );
    const url = new URL(request.url);

    await proxyToGitLab(request, url, env, mockCtx());

    const fetchCall = (env.GITLAB.fetch as ReturnType<typeof vi.fn>).mock
      .calls[0][0] as Request;
    expect(fetchCall.headers.get("X-Gitlab-Static-Object-Token")).toBe(
      "user-token-123",
    );
  });

  it("removes Set-Cookie from origin response", async () => {
    const env = mockEnv({
      GITLAB: {
        fetch: vi.fn().mockResolvedValue(
          new Response("body", {
            status: 200,
            headers: { "Set-Cookie": "session=abc; path=/" },
          }),
        ),
      } as unknown as Fetcher,
    });
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
    );
    const url = new URL(request.url);

    const response = await proxyToGitLab(request, url, env, mockCtx());
    expect(response.headers.get("Set-Cookie")).toBeNull();
  });

  it("returns X-Cache: REVALIDATED on 304 response", async () => {
    const env = mockEnv({
      GITLAB: {
        fetch: vi.fn().mockResolvedValue(new Response(null, { status: 304 })),
      } as unknown as Fetcher,
    });
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
      {
        headers: { "If-None-Match": '"etag-value"' },
      },
    );
    const url = new URL(request.url);

    const response = await proxyToGitLab(request, url, env, mockCtx());
    expect(response.status).toBe(304);
    expect(response.headers.get("X-Cache")).toBe("REVALIDATED");
  });

  it("passes through origin errors without caching", async () => {
    const env = mockEnv({
      GITLAB: {
        fetch: vi
          .fn()
          .mockResolvedValue(new Response("Not Found", { status: 404 })),
      } as unknown as Fetcher,
    });
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/missing.txt",
    );
    const url = new URL(request.url);

    const response = await proxyToGitLab(request, url, env, mockCtx());
    expect(response.status).toBe(404);
    expect(mockCache.put).not.toHaveBeenCalled();
  });

  it("builds origin URL with http://127.0.0.1", async () => {
    const env = mockEnv();
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
    );
    const url = new URL(request.url);

    await proxyToGitLab(request, url, env, mockCtx());

    const fetchCall = (env.GITLAB.fetch as ReturnType<typeof vi.fn>).mock
      .calls[0][0] as Request;
    const originUrl = new URL(fetchCall.url);
    expect(originUrl.protocol).toBe("http:");
    expect(originUrl.hostname).toBe("127.0.0.1");
    expect(originUrl.pathname).toBe("/group/project/raw/main/file.txt");
  });
});
