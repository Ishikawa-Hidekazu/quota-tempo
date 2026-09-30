#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const build = `${root}.build/debug`;
const output = `${root}dist/desktop-local-probe/QuotaTempoDesktopLocalProbe`;
execFileSync("swift", ["build", "--target", "QuotaTempoDesktopCandidate"], {
  cwd: root, stdio: "inherit", timeout: 120_000,
});
// SwiftPM's current map excludes stale object files left by older branches.
const objects = ["QuotaTempoDesktopCandidate", "QuotaTempoCore"].flatMap((target) => {
  const map = JSON.parse(readFileSync(`${build}/${target}.build/output-file-map.json`, "utf8"));
  return Object.values(map).map((entry) => entry.object).filter(Boolean);
});
mkdirSync(`${root}dist/desktop-local-probe`, { recursive: true, mode: 0o700 });
execFileSync("xcrun", [
  "swiftc", "-parse-as-library", "-I", `${build}/Modules`,
  `${root}scripts/desktop-candidate-local-probe.swift`, ...objects, "-o", output,
], { cwd: root, stdio: "inherit", timeout: 120_000 });
console.log("desktop_local_probe_built=true; not signed or executed");
