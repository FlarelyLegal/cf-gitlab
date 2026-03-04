import { describe, it, expect } from "vitest";
import { normalizeQuery } from "../index";

describe("normalizeQuery", () => {
  describe("raw file paths", () => {
    it("preserves inline=true", () => {
      const url = new URL(
        "http://127.0.0.1/group/project/raw/main/file.txt?inline=true",
      );
      const result = normalizeQuery(url);
      expect(result.searchParams.get("inline")).toBe("true");
    });

    it("preserves inline=false", () => {
      const url = new URL(
        "http://127.0.0.1/group/project/raw/main/file.txt?inline=false",
      );
      const result = normalizeQuery(url);
      expect(result.searchParams.get("inline")).toBe("false");
    });

    it("strips unknown query params on raw paths", () => {
      const url = new URL(
        "http://127.0.0.1/group/project/raw/main/file.txt?foo=bar&baz=1",
      );
      const result = normalizeQuery(url);
      expect(result.search).toBe("");
    });

    it("strips invalid inline values", () => {
      const url = new URL(
        "http://127.0.0.1/group/project/raw/main/file.txt?inline=maybe",
      );
      const result = normalizeQuery(url);
      expect(result.searchParams.has("inline")).toBe(false);
    });

    it("preserves the pathname", () => {
      const url = new URL(
        "http://127.0.0.1/group/project/raw/main/deep/path/file.txt?inline=true&junk=1",
      );
      const result = normalizeQuery(url);
      expect(result.pathname).toBe(
        "/group/project/raw/main/deep/path/file.txt",
      );
    });
  });

  describe("archive paths", () => {
    it("preserves append_sha=true", () => {
      const url = new URL(
        "http://127.0.0.1/group/project/-/archive/main/project-main.tar.gz?append_sha=true",
      );
      const result = normalizeQuery(url);
      expect(result.searchParams.get("append_sha")).toBe("true");
    });

    it("preserves append_sha=false", () => {
      const url = new URL(
        "http://127.0.0.1/group/project/-/archive/main/project-main.tar.gz?append_sha=false",
      );
      const result = normalizeQuery(url);
      expect(result.searchParams.get("append_sha")).toBe("false");
    });

    it("preserves path param", () => {
      const url = new URL(
        "http://127.0.0.1/group/project/-/archive/main/project-main.tar.gz?path=src/lib",
      );
      const result = normalizeQuery(url);
      expect(result.searchParams.get("path")).toBe("src/lib");
    });

    it("preserves both append_sha and path", () => {
      const url = new URL(
        "http://127.0.0.1/group/project/-/archive/main/project-main.tar.gz?append_sha=true&path=src",
      );
      const result = normalizeQuery(url);
      expect(result.searchParams.get("append_sha")).toBe("true");
      expect(result.searchParams.get("path")).toBe("src");
    });

    it("strips unknown query params on archive paths", () => {
      const url = new URL(
        "http://127.0.0.1/group/project/-/archive/main/project-main.tar.gz?foo=bar",
      );
      const result = normalizeQuery(url);
      expect(result.search).toBe("");
    });

    it("strips invalid append_sha values", () => {
      const url = new URL(
        "http://127.0.0.1/group/project/-/archive/main/project-main.tar.gz?append_sha=yes",
      );
      const result = normalizeQuery(url);
      expect(result.searchParams.has("append_sha")).toBe(false);
    });
  });

  describe("paths without raw or archive", () => {
    it("strips all query params for other paths", () => {
      const url = new URL(
        "http://127.0.0.1/group/project/-/blob/main/file.txt?foo=bar",
      );
      const result = normalizeQuery(url);
      expect(result.search).toBe("");
    });
  });
});
