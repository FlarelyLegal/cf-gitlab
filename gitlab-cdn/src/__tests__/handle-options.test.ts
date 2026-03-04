import { describe, it, expect } from "vitest";
import { handleOptions, CORS_HEADERS } from "../index";

describe("handleOptions", () => {
  it("returns CORS headers for full preflight request", () => {
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

    const response = handleOptions(request);
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe("*");
    expect(response.headers.get("Access-Control-Allow-Methods")).toBe(
      "GET, HEAD, OPTIONS",
    );
    expect(response.headers.get("Access-Control-Allow-Headers")).toBe(
      "X-Csrf-Token, X-Requested-With",
    );
  });

  it("returns Allow header for simple OPTIONS (no Origin)", () => {
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
      {
        method: "OPTIONS",
      },
    );

    const response = handleOptions(request);
    expect(response.headers.get("Allow")).toBe("GET, HEAD, OPTIONS");
    expect(response.headers.get("Access-Control-Allow-Origin")).toBeNull();
  });

  it("returns Allow header when Origin present but missing Request-Method", () => {
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
      {
        method: "OPTIONS",
        headers: {
          Origin: "https://example.com",
        },
      },
    );

    const response = handleOptions(request);
    expect(response.headers.get("Allow")).toBe("GET, HEAD, OPTIONS");
  });

  it("returns Allow header when Origin and Method present but missing Request-Headers", () => {
    const request = new Request(
      "https://cdn.example.com/group/project/raw/main/file.txt",
      {
        method: "OPTIONS",
        headers: {
          Origin: "https://example.com",
          "Access-Control-Request-Method": "GET",
        },
      },
    );

    const response = handleOptions(request);
    expect(response.headers.get("Allow")).toBe("GET, HEAD, OPTIONS");
  });
});
