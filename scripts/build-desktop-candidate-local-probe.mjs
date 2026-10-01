#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const build = `${root}.build/debug`;
const args = process.argv.slice(2);
if (args.length > 1 || (args.length === 1 && args[0] !== "--validation-only")) {
  throw new Error("Usage: build-desktop-candidate-local-probe.mjs [--validation-only]");
}
const liveOutput = `${root}dist/desktop-local-probe/QuotaTempoDesktopLocalProbe`;
const directory = `${root}dist/desktop-local-probe/${args.length ? "validation/" : ""}`;
const output = `${directory}QuotaTempoDesktopLocalProbe`;
if (!args.length) {
  const running = execFileSync("/bin/ps", ["-axo", "comm="], { encoding: "utf8" })
    .split("\n").some((line) => line.trim() === liveOutput);
  if (running) throw new Error("Preview is running; use --validation-only. It was not replaced.");
}
execFileSync("swift", ["build", "--target", "QuotaTempoDesktopCandidate"], {
  cwd: root, stdio: "inherit", timeout: 120_000,
});
// SwiftPM's current map excludes stale object files left by older branches.
const objects = ["QuotaTempoDesktopCandidate", "QuotaTempoCore"].flatMap((target) => {
  const map = JSON.parse(readFileSync(`${build}/${target}.build/output-file-map.json`, "utf8"));
  return Object.values(map).map((entry) => entry.object).filter(Boolean);
});
mkdirSync(directory, { recursive: true, mode: 0o700 });
execFileSync("xcrun", [
  "swiftc", "-swift-version", "6", "-parse-as-library", "-I", `${build}/Modules`,
  `${root}scripts/desktop-candidate-local-probe.swift`,
  `${root}scripts/desktop-preview-application.swift`, ...objects, "-o", output,
], { cwd: root, stdio: "inherit", timeout: 120_000 });
console.log("desktop_local_probe_built=true; not signed or executed");
