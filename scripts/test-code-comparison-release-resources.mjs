#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync,
  symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const builder = readFileSync(join(root, "scripts/build-app-bundle.sh"), "utf8");
const packaging = readFileSync(join(root, "scripts/package-release.sh"), "utf8");
const builderJS = builder.match(/node --input-type=module - "\$repo_root" "\$stage" <<'JS'\n([\s\S]*?)\nJS/)[1];
const signingShell = packaging.match(/(if \[\[ "\$sign_identity" != "-" \]\]; then\n  code_details=[\s\S]*?\nfi)\ncodesign "\$\{sign_args\[@\]\}" --identifier co\.ishikawa\.QuotaTempo "\$app"/)[1];
const files = [".claude-plugin/plugin.json", ".claude-plugin/marketplace.json", "hooks/hooks.json",
  "hooks/register.mjs", "producer.mjs", "protocol.mjs", "transport-crypto.mjs", "THIRD_PARTY_NOTICES.txt"];
function fixture(t) {
  const directory = realpathSync(mkdtempSync(join(tmpdir(), "qtc-release-resources-")));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const repo = join(directory, "repo"), stage = join(directory, "stage"), home = join(directory, "home");
  for (const path of [join(repo, "scripts"), join(repo, "Sources/QuotaTempoApp"),
    join(stage, "Contents/Resources"), home]) mkdirSync(path, { recursive: true, mode: 0o700 });
  copyFileSync(join(root, "scripts/package-code-comparison-plugin.mjs"), join(repo, "scripts/package-code-comparison-plugin.mjs"));
  const native = join(repo, "Sources/QuotaTempoApp/CodeComparisonPluginPackage.swift");
  copyFileSync(join(root, "Sources/QuotaTempoApp/CodeComparisonPluginPackage.swift"), native);
  for (const file of files) {
    const destination = join(repo, "experiments/claude-mods-usage", file);
    mkdirSync(dirname(destination), { recursive: true, mode: 0o700 });
    copyFileSync(join(root, "experiments/claude-mods-usage", file), destination);
  }
  const run = () => spawnSync(process.execPath, ["--input-type=module", "-", repo, stage], {
    input: builderJS, cwd: home, env: { HOME: home, PATH: "" }, encoding: "utf8", timeout: 10000, maxBuffer: 65536,
  });
  return { directory, repo, stage, home, native, run };
}
test("exact immutable plugin packages deterministically without Swift or signing", t => {
  const f = fixture(t), result = f.run();
  assert.equal(result.status, 0, result.stderr); assert.ifError(result.error);
  const manifest = readFileSync(join(f.stage, "Contents/Resources/CodeComparisonPlugin/quotatempo-package.json"));
  const other = fixture(t); assert.equal(other.run().status, 0);
  assert.deepEqual(readFileSync(join(other.stage, "Contents/Resources/CodeComparisonPlugin/quotatempo-package.json")), manifest);
});
for (const [name, mutate] of [
  ["unset compiled digest", f => writeFileSync(f.native, readFileSync(f.native, "utf8")
    .replace(/22024700344b34c645f47906425d90a375a46e14c1e3e17c90a729393215766c/g, "UNSET"))],
  ["incorrect compiled digest", f => writeFileSync(f.native, readFileSync(f.native, "utf8")
    .replace(/22024700344b34c645f47906425d90a375a46e14c1e3e17c90a729393215766c/g, "0".repeat(64)))],
  ["modified payload", f => writeFileSync(join(f.repo, "experiments/claude-mods-usage/producer.mjs"), "synthetic")],
  ["different plugin version", f => {
    for (const file of [".claude-plugin/plugin.json", ".claude-plugin/marketplace.json"]) {
      const path = join(f.repo, "experiments/claude-mods-usage", file);
      writeFileSync(path, readFileSync(path, "utf8").replaceAll("0.0.4", "0.0.5"));
    }
  }],
]) test(`builder rejects ${name}`, t => {
  const f = fixture(t); mutate(f); const result = f.run();
  assert.ifError(result.error); assert.notEqual(result.status, 0);
});
for (const [name, details, expected] of [
  ["pinned Developer ID publisher", "Identifier=co.ishikawa.QuotaTempo\nAuthority=Developer ID Application: Synthetic\nTeamIdentifier=9AQKR642UU", 0],
  ["different Developer ID publisher", "Identifier=co.ishikawa.QuotaTempo\nAuthority=Developer ID Application: Synthetic\nTeamIdentifier=WRONGTEAM1", 2],
  ["non-Developer ID certificate with correct team", "Identifier=co.ishikawa.QuotaTempo\nAuthority=Apple Development: Synthetic\nTeamIdentifier=9AQKR642UU", 2],
  ["missing team", "Identifier=co.ishikawa.QuotaTempo\nAuthority=Developer ID Application: Synthetic", 2],
  ["wrong nested identifier", "Identifier=QuotaTempo\nAuthority=Developer ID Application: Synthetic\nTeamIdentifier=9AQKR642UU", 2],
]) test(`signing metadata gate: ${name}`, t => {
  const f = fixture(t), bin = join(f.directory, "bin"); mkdirSync(bin);
  for (const [tool, destination] of [["awk", "/usr/bin/awk"], ["grep", "/usr/bin/grep"]]) symlinkSync(destination, join(bin, tool));
  writeFileSync(join(bin, "codesign"), `#!/bin/bash\nprintf '%s\\n' '${details}' >&2\n`, { mode: 0o755 });
  writeFileSync(join(bin, "plist"), "#!/bin/bash\nprintf '%s\\n' \"$*\"\n", { mode: 0o755 });
  chmodSync(join(bin, "codesign"), 0o755); chmodSync(join(bin, "plist"), 0o755);
  const result = spawnSync("/bin/bash", ["-c", `set -euo pipefail\nsign_identity=synthetic\napp=synthetic.app\nplist=plist\n${signingShell}`], {
    cwd: f.home, env: { HOME: f.home, PATH: bin }, encoding: "utf8", timeout: 10000, maxBuffer: 65536,
  });
  assert.ifError(result.error); assert.equal(result.status, expected, result.stderr);
  if (!expected) assert.match(result.stdout, /Add :QTCodeComparisonSigningTeam string 9AQKR642UU/);
  else assert.doesNotMatch(result.stdout, /QTCodeComparisonSigningTeam/);
});
test("release sequencing seals metadata and includes resources before public inventory", () => {
  assert(builder.indexOf("await packPlugin") < builder.indexOf('find "$stage" -type d'));
  assert(builder.indexOf("CodePluginTools/$tool") < builder.indexOf("shasum -a 256 \"$file\""));
  assert.match(builder, /verifyPackage\(destination\)/);
  assert.match(builder, /result\.marketplaceName !== marketplaceName/);
  const outerSign = 'codesign "${sign_args[@]}" --identifier co.ishikawa.QuotaTempo "$app"';
  assert(packaging.indexOf("Set :QTCodeComparisonSigningMode developer-id") < packaging.indexOf(outerSign));
  assert(packaging.indexOf("Add :QTCodeComparisonSigningTeam") < packaging.indexOf(outerSign));
  assert(builder.includes('--identifier co.ishikawa.QuotaTempo "$binary_stage/QuotaTempo"'));
  assert(packaging.includes('codesign "${sign_args[@]}" --identifier co.ishikawa.QuotaTempo "$app/Contents/MacOS/QuotaTempo"'));
  assert(packaging.includes('codesign "${sign_args[@]}" "$app/Contents/MacOS/QuotaTempoBrowserHost"'));
  assert(!packaging.includes('--identifier co.ishikawa.QuotaTempo "$app/Contents/MacOS/QuotaTempoBrowserHost"'));
  assert.match(packaging, /Print :QTCodeComparisonSigningTeam[\s\S]*?== "\$team_identifier"/);
  const plist = readFileSync(join(root, "packaging/Info.plist"), "utf8");
  assert.match(plist, /<key>QTCodeComparisonPluginBundled<\/key>\s*<true\/>/);
  assert.match(plist, /<key>QTCodeComparisonSigningMode<\/key>\s*<string>local-ad-hoc<\/string>/);
  assert.match(plist, /<key>SUFeedURL<\/key>/);
  assert.doesNotMatch(plist, /CodeComparisonPreview|code-comparison-preview/);
});
test("owned shell scripts parse without executing builds, signing or state access", () => {
  for (const file of ["build-app-bundle.sh", "package-release.sh", "check-desktop-artifact-isolation.sh"]) {
    const result = spawnSync("/bin/bash", ["-n", join(root, "scripts", file)], {
      env: { PATH: "" }, encoding: "utf8", timeout: 10000, maxBuffer: 65536,
    });
    assert.ifError(result.error); assert.equal(result.signal, null); assert.equal(result.status, 0, result.stderr);
  }
});
