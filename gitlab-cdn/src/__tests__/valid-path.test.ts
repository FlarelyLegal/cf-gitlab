import { describe, it, expect } from "vitest";
import { VALID_PATH } from "../index";

describe("VALID_PATH regex", () => {
  describe("valid paths", () => {
    it("matches raw file path", () => {
      expect(VALID_PATH.test("/group/project/raw/main/file.txt")).toBe(true);
    });

    it("matches raw path with nested groups", () => {
      expect(
        VALID_PATH.test("/group/subgroup/project/raw/main/dir/file.txt"),
      ).toBe(true);
    });

    it("matches archive path", () => {
      expect(
        VALID_PATH.test("/group/project/-/archive/main/project-main.tar.gz"),
      ).toBe(true);
    });

    it("matches archive path with nested groups", () => {
      expect(
        VALID_PATH.test(
          "/group/subgroup/project/-/archive/v1.0.0/project-v1.0.0.zip",
        ),
      ).toBe(true);
    });

    it("matches raw path with ref containing slashes", () => {
      expect(
        VALID_PATH.test("/group/project/raw/feature/branch/file.txt"),
      ).toBe(true);
    });
  });

  describe("invalid paths", () => {
    it("rejects root path", () => {
      expect(VALID_PATH.test("/")).toBe(false);
    });

    it("rejects blob path", () => {
      expect(VALID_PATH.test("/group/project/-/blob/main/file.txt")).toBe(
        false,
      );
    });

    it("rejects tree path", () => {
      expect(VALID_PATH.test("/group/project/-/tree/main")).toBe(false);
    });

    it("rejects API path", () => {
      expect(VALID_PATH.test("/api/v4/projects/1/repository/files")).toBe(
        false,
      );
    });

    it("rejects empty path", () => {
      expect(VALID_PATH.test("")).toBe(false);
    });

    it("rejects path with only raw (no leading content)", () => {
      expect(VALID_PATH.test("/raw/")).toBe(false);
    });

    it("rejects merge request path", () => {
      expect(VALID_PATH.test("/group/project/-/merge_requests/1")).toBe(false);
    });

    it("rejects pipeline path", () => {
      expect(VALID_PATH.test("/group/project/-/pipelines/123")).toBe(false);
    });

    it("rejects settings path", () => {
      expect(VALID_PATH.test("/admin/application_settings")).toBe(false);
    });
  });
});
