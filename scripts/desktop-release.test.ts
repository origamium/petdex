import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import {
  desktopAssets,
  desktopRoot,
  parseDesktopTag,
  verifyDesktopVersion,
} from "./desktop-release-config";
import { verifyDesktopAssets } from "./verify-desktop-release";

const directories: string[] = [];
function temporaryDirectory() {
  const dir = mkdtempSync(path.join(tmpdir(), "petdex-release-test-"));
  directories.push(dir);
  return dir;
}
afterEach(() => {
  for (const dir of directories.splice(0))
    rmSync(dir, { recursive: true, force: true });
});

describe("publication failure handling", () => {
  function publish(state: string, keepDraft = false, failUpload = false) {
    const dir = temporaryDirectory();
    const bin = path.join(dir, "bin");
    const log = path.join(dir, "calls");
    mkdirSync(bin);
    mkdirSync(path.join(dir, "release"));
    writeFileSync(path.join(dir, "release/SHA256SUMS"), "fixture");
    writeFileSync(log, "");
    writeFileSync(
      path.join(bin, "gh"),
      `#!/usr/bin/env bash
set -eu
printf '%s\\n' "$*" >> "$MOCK_CALLS"
case "$1 $2" in
  'api --paginate')
    case "$MOCK_STATE" in
      error) exit 1 ;;
      published) printf '%s\\tfalse\\n' "$RELEASE_TAG" ;;
      draft) printf '%s\\ttrue\\n' "$RELEASE_TAG" ;;
    esac ;;
  'release upload') [[ "$MOCK_UPLOAD_FAIL" != true ]] ;;
  'release create'|'release edit') exit 0 ;;
  *) exit 99 ;;
esac
`,
      { mode: 0o755 },
    );
    const workflow = Bun.YAML.parse(
      readFileSync(
        path.join(desktopRoot, ".github/workflows/desktop-release.yml"),
        "utf8",
      ),
    ) as {
      jobs: { release: { steps: { name?: string; run?: string }[] } };
    };
    const script = workflow.jobs.release.steps.find(
      (step) => step.name === "Upload assets to a draft, then publish",
    )?.run;
    if (!script) throw new Error("Publication step missing");
    const result = spawnSync("bash", ["-e", "-o", "pipefail", "-c", script], {
      cwd: dir,
      encoding: "utf8",
      env: {
        PATH: `${bin}:${process.env.PATH}`,
        GH_REPO: "example/petdex",
        RELEASE_TAG: "desktop-v1.2.3",
        PRERELEASE: "false",
        KEEP_DRAFT: String(keepDraft),
        GITHUB_STEP_SUMMARY: path.join(dir, "summary"),
        MOCK_CALLS: log,
        MOCK_STATE: state,
        MOCK_UPLOAD_FAIL: String(failUpload),
      },
    });
    return { status: result.status, calls: readFileSync(log, "utf8") };
  }
  test("creates a draft, uploads, then publishes in the current repository", () => {
    const { status, calls } = publish("missing");
    expect(status).toBe(0);
    expect(calls).toContain("repos/example/petdex/releases");
    expect(calls).toContain("--draft");
    expect(calls.indexOf("release create")).toBeLessThan(
      calls.indexOf("release upload"),
    );
    expect(calls.indexOf("release upload")).toBeLessThan(
      calls.indexOf("release edit"),
    );
  });
  test("API and upload errors never result in publication", () => {
    for (const [state, failUpload] of [
      ["error", false],
      ["missing", true],
    ] as const) {
      const result = publish(state, false, failUpload);
      expect(result.status).not.toBe(0);
      expect(result.calls).not.toContain("release edit");
      if (state === "error")
        expect(result.calls).not.toContain("release create");
    }
  });
  test("retries a draft without duplicating or publishing it when draft is selected", () => {
    const result = publish("draft", true);
    expect(result.status).toBe(0);
    expect(result.calls).toContain("release upload");
    expect(result.calls).not.toContain("release create");
    expect(result.calls).not.toContain("release edit");
  });
  test("published releases are never overwritten", () => {
    const result = publish("published");
    expect(result.status).not.toBe(0);
    expect(result.calls).not.toContain("release upload");
    expect(result.calls).not.toContain("release edit");
  });
});

describe("release identity", () => {
  test("stable and prerelease tags preserve the numeric bundle version", () => {
    expect(parseDesktopTag("desktop-v1.2.3")).toEqual({
      tag: "desktop-v1.2.3",
      version: "1.2.3",
      prerelease: false,
    });
    for (const label of ["alpha", "beta", "rc"]) {
      expect(parseDesktopTag(`desktop-v1.2.3-${label}.1`).prerelease).toBe(
        true,
      );
      expect(parseDesktopTag(`desktop-v1.2.3-${label}.1`).version).toBe(
        "1.2.3",
      );
    }
  });
  test("rejects refs, malformed versions and shell input", () => {
    for (const tag of [
      "main",
      "v1.2.3",
      "desktop-v01.2.3",
      "desktop-v1.2",
      "desktop-v1.2.3-rc",
      "desktop-v1.2.3-rc.01",
      "desktop-v1.2.3\n",
      "desktop-v1.2.3\ncommit=bad",
      "desktop-v1.2.3;echo bad",
    ]) {
      expect(() => parseDesktopTag(tag)).toThrow();
    }
  });
  test("refuses tag/manifest or tested/released SDK drift", () => {
    const dir = temporaryDirectory();
    const pkg = path.join(dir, "packages/petdex-desktop-native");
    const workflows = path.join(dir, ".github/workflows");
    mkdirSync(pkg, { recursive: true });
    mkdirSync(workflows, { recursive: true });
    writeFileSync(path.join(pkg, "app.zon"), '.{ .version = "1.2.3" }');
    writeFileSync(path.join(pkg, "app.package.json"), '{"version":"1.2.3"}');
    for (const name of ["desktop-native-ci.yml", "desktop-release.yml"]) {
      writeFileSync(
        path.join(workflows, name),
        `NATIVE_SDK_REF: "${"a".repeat(40)}"`,
      );
    }
    expect(verifyDesktopVersion("desktop-v1.2.3-rc.1", dir).version).toBe(
      "1.2.3",
    );
    expect(() => verifyDesktopVersion("desktop-v1.2.4", dir)).toThrow(
      "must match",
    );
    writeFileSync(path.join(pkg, "app.package.json"), '{"version":"1.2.4"}');
    expect(() => verifyDesktopVersion("desktop-v1.2.3", dir)).toThrow(
      "must match",
    );
    writeFileSync(path.join(pkg, "app.package.json"), '{"version":"1.2.3"}');
    writeFileSync(
      path.join(workflows, "desktop-release.yml"),
      `NATIVE_SDK_REF: "${"b".repeat(40)}"`,
    );
    expect(() => verifyDesktopVersion("desktop-v1.2.3", dir)).toThrow(
      "same Native SDK",
    );
  });
});

describe("complete release before publication", () => {
  function stage() {
    const dir = temporaryDirectory();
    for (const name of desktopAssets)
      writeFileSync(path.join(dir, name), "abc");
    return dir;
  }
  test("checksums all platforms, including compatibility asset names", () => {
    const dir = stage();
    verifyDesktopAssets(dir);
    const sums = readFileSync(path.join(dir, "SHA256SUMS"), "utf8");
    expect(sums.trim().split("\n")).toHaveLength(11);
    expect(sums).toContain(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  Petdex-arm64.dmg",
    );
    verifyDesktopAssets(dir); // A retry regenerates the checksum file.
    expect(readFileSync(path.join(dir, "SHA256SUMS"), "utf8")).toBe(sums);
  });
  test("missing or empty platform files cannot publish", () => {
    for (const missing of desktopAssets) {
      const dir = stage();
      rmSync(path.join(dir, missing));
      expect(() => verifyDesktopAssets(dir)).toThrow();
      writeFileSync(path.join(dir, missing), "");
      expect(() => verifyDesktopAssets(dir)).toThrow("empty");
    }
  });
  test("unsigned previews and unexpected files cannot enter a release", () => {
    const dir = stage();
    writeFileSync(path.join(dir, "Petdex-arm64-unsigned.dmg"), "preview");
    expect(() => verifyDesktopAssets(dir)).toThrow("exactly");
  });
});
