import { createHash } from "node:crypto";
import {
  appendFileSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";

import { desktopAssets, verifyDesktopVersion } from "./desktop-release-config";

export function verifyDesktopAssets(directory: string) {
  const actual = readdirSync(directory).filter((name) => name !== "SHA256SUMS");
  if (
    actual.length !== desktopAssets.length ||
    actual.some(
      (name) => !desktopAssets.includes(name as (typeof desktopAssets)[number]),
    )
  ) {
    throw new Error(
      "Release must contain exactly the expected macOS, Linux and Windows assets",
    );
  }
  const checksums = desktopAssets
    .map((name) => {
      const file = path.join(directory, name);
      if (!statSync(file).isFile() || statSync(file).size === 0) {
        throw new Error(`Missing or empty release asset: ${name}`);
      }
      return `${createHash("sha256").update(readFileSync(file)).digest("hex")}  ${name}\n`;
    })
    .join("");
  writeFileSync(path.join(directory, "SHA256SUMS"), checksums);
}

if (import.meta.main) {
  const [tag, directory] = process.argv.slice(2);
  const release = verifyDesktopVersion(tag ?? "");
  if (process.env.NATIVE_SDK_REF) {
    const source = readFileSync(
      new URL("../.github/workflows/desktop-native-ci.yml", import.meta.url),
      "utf8",
    );
    if (!source.includes(`NATIVE_SDK_REF: "${process.env.NATIVE_SDK_REF}"`)) {
      throw new Error(
        "The running workflow uses a different SDK pin; select the release tag as the workflow ref",
      );
    }
  }
  if (directory) verifyDesktopAssets(directory);
  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(
      process.env.GITHUB_OUTPUT,
      `tag=${release.tag}\nversion=${release.version}\nprerelease=${release.prerelease}\n`,
    );
  }
  console.log(
    `Verified ${release.tag}${directory ? " and all release assets" : ""}`,
  );
}
