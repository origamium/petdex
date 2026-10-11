#!/usr/bin/env bun
// Tag the exact committed source. GitHub Actions owns builds and publication.
import { spawnSync } from "node:child_process";

import { desktopRoot, verifyDesktopVersion } from "./desktop-release-config";

function git(args: string[]) {
  const result = spawnSync("git", args, { cwd: desktopRoot, encoding: "utf8" });
  if (result.status !== 0)
    throw new Error(result.stderr.trim() || `git ${args[0]} failed`);
  return result.stdout.trim();
}

function main() {
  const args = process.argv.slice(2);
  if (args.includes("--help")) {
    console.log(
      "Usage: bun run release:desktop <X.Y.Z[-rc.N]> [--dry-run]\nCommit matching app.zon/app.package.json versions first. See docs/desktop-releases.md.\nFor a draft or a retry, use the desktop release workflow's Run workflow form.",
    );
    return;
  }
  const versions = args.filter((arg) => !arg.startsWith("--"));
  if (
    versions.length !== 1 ||
    args.some((arg) => arg.startsWith("--") && arg !== "--dry-run")
  ) {
    throw new Error(
      "Usage: bun run release:desktop <version> [--dry-run]. Builds, signing and release notes now run in GitHub Actions; see docs/desktop-releases.md.",
    );
  }
  const tag = `desktop-v${versions[0].replace(/^(desktop-v|v)/, "")}`;
  verifyDesktopVersion(tag);
  if (git(["status", "--porcelain"]))
    throw new Error("Commit or stash working-tree changes before releasing");
  const remote = git(["remote", "get-url", "origin"]);
  if (
    !/^(git@github\.com:|https:\/\/github\.com\/|ssh:\/\/git@github\.com\/)[\w.-]+\/[\w.-]+(?:\.git)?$/.test(
      remote,
    )
  ) {
    throw new Error(
      "origin must point to the GitHub repository that will publish the release",
    );
  }
  if (
    git(["tag", "--list", tag]) ||
    git(["ls-remote", "--tags", "origin", `refs/tags/${tag}`])
  ) {
    throw new Error(
      `${tag} already exists; retry its GitHub Actions run instead of moving the tag`,
    );
  }
  console.log(`${tag}: ${git(["rev-parse", "HEAD"])} -> ${remote}`);
  if (args.includes("--dry-run")) {
    console.log("Dry run complete; no tag was created or pushed.");
    return;
  }
  git(["tag", "-a", tag, "-m", `Petdex ${tag.slice("desktop-v".length)}`]);
  git(["push", "origin", `refs/tags/${tag}`]);
  console.log(
    "Tag pushed. The desktop release workflow will build, sign, notarize and publish all platforms.",
  );
}

try {
  main();
} catch (error) {
  console.error(
    `release-desktop: ${error instanceof Error ? error.message : error}`,
  );
  process.exitCode = 1;
}
