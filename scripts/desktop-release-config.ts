import { readFileSync } from "node:fs";
import path from "node:path";

export const desktopRoot = path.resolve(import.meta.dir, "..");

// CFBundleShortVersionString stays numeric, including prerelease builds.
export function parseDesktopTag(tag: string) {
  const match =
    /^desktop-v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))(-(alpha|beta|rc)\.(0|[1-9]\d*))?$/.exec(
      tag,
    );
  if (!match || match[0] !== tag) {
    throw new Error(
      "Expected desktop-vX.Y.Z or desktop-vX.Y.Z-{alpha,beta,rc}.N",
    );
  }
  return { tag, version: match[1], prerelease: Boolean(match[2]) };
}

export function verifyDesktopVersion(tag: string, root = desktopRoot) {
  const release = parseDesktopTag(tag);
  const pkg = path.join(root, "packages/petdex-desktop-native");
  const zon = readFileSync(path.join(pkg, "app.zon"), "utf8");
  const zonVersion = zon.match(/\.version\s*=\s*"([^"]+)"/)?.[1];
  const manifest = JSON.parse(
    readFileSync(path.join(pkg, "app.package.json"), "utf8"),
  );
  if (zonVersion !== release.version || manifest.version !== release.version) {
    throw new Error(
      `Tag version ${release.version} must match app.zon (${zonVersion}) and app.package.json (${manifest.version})`,
    );
  }
  const ci = readFileSync(
    path.join(root, ".github/workflows/desktop-native-ci.yml"),
    "utf8",
  );
  const workflow = readFileSync(
    path.join(root, ".github/workflows/desktop-release.yml"),
    "utf8",
  );
  const pins = [ci, workflow].map(
    (source) => source.match(/NATIVE_SDK_REF:\s*"([0-9a-f]{40})"/)?.[1],
  );
  if (!pins[0] || pins[0] !== pins[1]) {
    throw new Error(
      "Desktop CI and release must use the same Native SDK commit",
    );
  }
  return release;
}

export const desktopAssets = [
  "Petdex-arm64.dmg",
  "petdex-desktop-native-darwin-arm64.zip",
  "petdex-desktop-darwin-arm64.zip",
] as const;
