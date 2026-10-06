#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync,
  rmSync, symlinkSync, writeFileSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { packPlugin, PLUGIN_FILES, verifyPackage } from "./package-code-comparison-plugin.mjs";

const source = readFileSync(new URL("./build-code-comparison-preview.sh", import.meta.url), "utf8");
const namespace = "quotatempo-code-d276298d-6c66-477a-8c58-cf2b5d8e6104";
const team = "TESTTEAM01";
const signing = ["--sign-identity", `Developer ID Application: Fixture (${team})`, "--team-id", team];

async function fixture(t) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "Code Preview Builder QA ")));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const repo = join(root, "repo");
  const bin = join(root, "bin");
  const home = join(root, "empty-home");
  const output = join(root, "output", "Code.app");
  const payload = join(repo, "experiments/claude-mods-usage");
  const native = join(repo, "Sources/QuotaTempoApp/CodeComparisonPluginPackage.swift");
  const script = join(repo, "scripts/build-code-comparison-preview.sh");
  for (const path of [bin, home, dirname(native), dirname(script), dirname(output),
    join(payload, ".claude-plugin"), join(payload, "hooks")]) mkdirSync(path, { recursive: true });
  for (const file of PLUGIN_FILES) writeFileSync(join(payload, file), "inert synthetic bytes\n");
  writeFileSync(join(payload, PLUGIN_FILES[0]), JSON.stringify({ name: "quotatempo-usage-probe", version: "0.0.4" }));
  writeFileSync(join(payload, PLUGIN_FILES[1]), JSON.stringify({ name: "source-fixture", metadata: { version: "0.0.4" },
    plugins: [{ name: "quotatempo-usage-probe", source: "./" }] }));
  const reference = join(root, "reference");
  await packPlugin({ source: payload, destination: reference, marketplaceName: namespace });
  const digest = createHash("sha256").update(readFileSync(join(reference, "quotatempo-package.json"))).digest("hex");
  writeFileSync(native, `  static let nativeMarketplaceName = "${namespace}"\n  static let nativeManifestDigest = "${digest}"\n`);
  assert.equal(source.match(/\/usr\/libexec\/PlistBuddy/g)?.length, 1);
  writeFileSync(script, source.replace("/usr/libexec/PlistBuddy", '"$TEST_PLIST"'));
  copyFileSync(fileURLToPath(new URL("./package-code-comparison-plugin.mjs", import.meta.url)),
    join(repo, "scripts/package-code-comparison-plugin.mjs"));
  for (const [name, path] of Object.entries({ dirname: "/usr/bin/dirname", mkdir: "/bin/mkdir",
    mktemp: "/usr/bin/mktemp", rm: "/bin/rm", bash: "/bin/bash", node: process.execPath }))
    symlinkSync(path, join(bin, name));
  const stub = join(root, "stub.mjs");
  const log = join(root, "calls.jsonl");
  writeFileSync(stub, `import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
const [tool, ...args] = process.argv.slice(2), env = process.env;
appendFileSync(env.TEST_LOG, JSON.stringify({tool, args})+'\\n');
const fail = phase => { if (env.TEST_FAIL === phase) process.exit(67); };
if (tool === 'base') {
  fail('base');
  const app = args[0];
  for (const dir of ['Contents/MacOS','Contents/Resources']) mkdirSync(join(app,dir),{recursive:true});
  writeFileSync(join(app,'Contents/MacOS/QuotaTempo'),'inert binary');
  const info = {CFBundleIdentifier:'co.ishikawa.QuotaTempo.DesktopIntegrationPreview', CFBundleName:'Preview',
    CFBundleDisplayName:'Preview', QTReleaseChannel:'desktop-integration-preview'};
  Object.assign(info, JSON.parse(env.TEST_INHERITED || '{}'));
  if (env.TEST_FAIL === 'feed') info.SUFeedURL = 'forbidden';
  if (env.TEST_FAIL === 'release-key') info.SUPublicEDKey = 'forbidden';
  writeFileSync(join(app,'Contents/Info.plist'),JSON.stringify(info));
  process.stdout.write('intermediate builder success must be hidden');
} else if (tool === 'plist') {
  fail('plist');
  const [op,key,...value] = args[1].split(' '), path = args[2];
  const info = JSON.parse(readFileSync(path,'utf8'));
  if(op === 'Print') {
    if(!key) process.stdout.write(JSON.stringify(info));
    else if(Object.hasOwn(info,key.slice(1))) process.stdout.write(String(info[key.slice(1)]));
    else process.exit(1);
  } else {
    const name = key.slice(1), present = Object.hasOwn(info,name);
    if(op === 'Add') {
      if(present) { process.stderr.write('Entry Already Exists\\n'); process.exit(1); }
      info[name] = value[0] === 'bool' ? value[1] === 'true' : value.slice(1).join(' ');
    } else if(op === 'Set') {
      if(!present) process.exit(1);
      info[name] = value.join(' ');
    } else if(op === 'Delete') {
      fail('delete');
      if(!present) process.exit(1);
      delete info[name];
    } else process.exit(98);
    writeFileSync(path,JSON.stringify(info));
  }
} else if(tool === 'codesign') {
  if(!existsSync(args.at(-1))) process.exit(98);
  if(args.includes('--sign')) {
    fail('sign');
    const app = args.at(-1).endsWith('.app') ? args.at(-1) : dirname(dirname(dirname(args.at(-1))));
    const info = JSON.parse(readFileSync(join(app,'Contents/Info.plist'),'utf8'));
    if(!info.QTCodeComparisonManifestDigest || !info.QTCodeComparisonPluginBundled ||
      !existsSync(join(app,'Contents/Resources/CodeComparisonPlugin/quotatempo-package.json'))) process.exit(98);
  } else {
    fail(args.includes('--test-requirement') ? 'requirement' : 'verify');
    if(env.TEST_FAIL === 'tamper') writeFileSync(join(args.at(-1),'Contents/Resources/CodeComparisonPlugin/producer.mjs'),'tampered');
    if(env.TEST_FAIL === 'late-identity' || env.TEST_FAIL === 'late-team') {
      const path = join(args.at(-1),'Contents/Info.plist'), info = JSON.parse(readFileSync(path,'utf8'));
      if(env.TEST_FAIL === 'late-identity') info.CFBundleIdentifier = 'co.ishikawa.QuotaTempo';
      else info.QTCodeComparisonSigningTeam = 'OLDTEAM001';
      writeFileSync(path,JSON.stringify(info));
    }
    if(env.TEST_FAIL === 'late-collision') { mkdirSync(env.TEST_OUTPUT); writeFileSync(join(env.TEST_OUTPUT,'keep'),'preserve'); }
  }
} else if(tool === 'mv') { fail('publish'); renameSync(args[0],args[1]); }
else process.exit(99);
`);
  for (const tool of ["plist", "codesign", "mv"]) writeFileSync(join(bin, tool),
    `#!/bin/sh\nexec "$TEST_NODE" "$TEST_STUB" ${tool} "$@"\n`, { mode: 0o755 });
  writeFileSync(join(repo, "scripts/build-desktop-integration-preview.sh"),
    '#!/bin/bash\nexec "$TEST_NODE" "$TEST_STUB" base "$@"\n');
  const env = { PATH: bin, HOME: home, TMPDIR: root, LC_ALL: "C", TEST_NODE: process.execPath,
    TEST_STUB: stub, TEST_LOG: log, TEST_OUTPUT: output, TEST_PLIST: join(bin, "plist") };
  const run = (args = [output], overrides = {}) => {
    const result = spawnSync("/bin/bash", [script, ...args], { cwd: home, env: { ...env, ...overrides },
      encoding: "utf8", timeout: 15000, maxBuffer: 65536 });
    assert.ifError(result.error);
    assert.equal(result.signal, null);
    return result;
  };
  const noStage = () => assert.equal(readdirSync(dirname(output)).some(n => n.startsWith(".CodeComparison.")), false);
  const calls = () => existsSync(log) ? readFileSync(log,"utf8").trim().split("\n").map(JSON.parse) : [];
  return { root, repo, home, output, native, payload, digest, run, noStage, calls };
}

for (const signed of [false, true]) test(`fresh pinned preview; signing=${signed}`, async t => {
  const f = await fixture(t);
  const result = f.run([f.output, ...(signed ? signing : [])]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Built Code comparison preview/, result.stderr);
  assert.doesNotMatch(result.stdout, /intermediate builder/);
  const info = JSON.parse(readFileSync(join(f.output,"Contents/Info.plist"),"utf8"));
  assert.equal(info.CFBundleIdentifier,"co.ishikawa.QuotaTempo.CodeComparisonPreview");
  assert.equal(info.QTReleaseChannel,"code-comparison-preview");
  assert.equal(info.QTCodeComparisonManifestDigest,f.digest);
  assert.equal(info.QTCodeComparisonSigningMode,signed ? "developer-id" : "local-ad-hoc");
  assert.equal(info.QTCodeComparisonSigningTeam,signed ? team : undefined);
  assert.equal(info.SUFeedURL,undefined);
  const packaged = await verifyPackage(join(f.output,"Contents/Resources/CodeComparisonPlugin"));
  assert.equal(packaged.version,"0.0.4");
  assert.equal(packaged.marketplaceName,namespace);
  const signCalls = f.calls().filter(c => c.tool === "codesign");
  assert.equal(signCalls.length,signed ? 4 : 3);
  if(signed) assert.match(signCalls.at(-1).args.join(" "),/co\.ishikawa\.QuotaTempo\.CodeComparisonPreview/);
  assert.deepEqual(readdirSync(f.home),[]);
  f.noStage();
});

for (const [name, inherited] of [
  ["normal public metadata", {
    QTCodeComparisonPluginBundled: true,
    QTCodeComparisonManifestDigest: "22024700344b34c645f47906425d90a375a46e14c1e3e17c90a729393215766c",
    QTCodeComparisonSigningMode: "local-ad-hoc",
  }],
  ["previous Developer ID metadata", {
    QTCodeComparisonPluginBundled: false, QTCodeComparisonManifestDigest: "0".repeat(64),
    QTCodeComparisonSigningMode: "developer-id", QTCodeComparisonSigningTeam: "OLDTEAM001",
  }],
  ["incompatible inherited types", {
    QTCodeComparisonPluginBundled: "false", QTCodeComparisonManifestDigest: 17,
    QTCodeComparisonSigningMode: true, QTCodeComparisonSigningTeam: false,
  }],
]) for (const signed of [false, true]) test(`replace ${name}; signing=${signed}`, async t => {
  const f = await fixture(t);
  const result = f.run([f.output, ...(signed ? signing : [])], { TEST_INHERITED: JSON.stringify(inherited) });
  assert.equal(result.status, 0, result.stderr);
  const info = JSON.parse(readFileSync(join(f.output, "Contents/Info.plist"), "utf8"));
  assert.equal(info.CFBundleIdentifier, "co.ishikawa.QuotaTempo.CodeComparisonPreview");
  assert.equal(info.QTReleaseChannel, "code-comparison-preview");
  assert.equal(info.QTCodeComparisonPluginBundled, true);
  assert.equal(info.QTCodeComparisonManifestDigest, f.digest);
  assert.equal(info.QTCodeComparisonSigningMode, signed ? "developer-id" : "local-ad-hoc");
  assert.equal(info.QTCodeComparisonSigningTeam, signed ? team : undefined);
  assert.equal(Object.hasOwn(info, "QTCodeComparisonSigningTeam"), signed);
  for (const key of ["SUFeedURL", "SUPublicEDKey"]) assert.equal(Object.hasOwn(info, key), false);
  const calls = f.calls();
  const firstSign = calls.findIndex(call => call.tool === "codesign");
  for (const key of Object.keys(inherited)) {
    const deletion = calls.findIndex(call => call.tool === "plist" && call.args[1] === `Delete :${key}`);
    assert(deletion >= 0 && deletion < firstSign, `Inherited ${key} must be removed before signing`);
  }
  assert.equal((await verifyPackage(join(f.output, "Contents/Resources/CodeComparisonPlugin"))).packageDigest, f.digest);
  assert.deepEqual(readdirSync(f.home), []);
  f.noStage();
});

test("failure to remove inherited metadata cannot sign or publish", async t => {
  const f = await fixture(t);
  const result = f.run([f.output, ...signing], {
    TEST_INHERITED: JSON.stringify({ QTCodeComparisonSigningTeam: "OLDTEAM001" }), TEST_FAIL: "delete",
  });
  assert.notEqual(result.status, 0);
  assert.doesNotMatch(result.stdout, /Built Code comparison preview/);
  assert.equal(f.calls().some(call => call.tool === "codesign"), false);
  assert.equal(existsSync(f.output), false);
  f.noStage();
});

for (const phase of ["base","plist","feed","release-key","sign","verify","requirement","tamper",
  "late-identity","late-team","publish","late-collision"])
  test(`fail closed: ${phase}`, async t => {
    const f = await fixture(t);
    const result = f.run([f.output,...signing],{TEST_FAIL:phase});
    assert.notEqual(result.status,0, JSON.stringify({ phase, info: existsSync(join(f.output,"Contents/Info.plist"))
      ? JSON.parse(readFileSync(join(f.output,"Contents/Info.plist"),"utf8")) : null }));
    assert.doesNotMatch(result.stdout,/Built Code comparison preview/);
    f.noStage();
    if(phase === "late-collision") assert.equal(readFileSync(join(f.output,"keep"),"utf8"),"preserve");
    else if(phase !== "publish") assert.equal(existsSync(f.output),false);
  });

test("ad-hoc preview refuses a signing team introduced after signing", async t => {
  const f = await fixture(t);
  const result = f.run([f.output], { TEST_FAIL: "late-team" });
  assert.notEqual(result.status, 0);
  assert.doesNotMatch(result.stdout, /Built Code comparison preview/);
  assert.equal(existsSync(f.output), false);
  f.noStage();
});

for (const kind of ["unset","mismatch","duplicate","source-change"])
  test(`compiled pin refuses ${kind}`, async t => {
    const f = await fixture(t);
    if(kind === "source-change") writeFileSync(join(f.payload,"producer.mjs"),"changed resource");
    else {
      const original = readFileSync(f.native,"utf8");
      writeFileSync(f.native,kind === "duplicate" ? original + original : original.replace(f.digest,kind === "unset" ? "UNSET" : "0".repeat(64)));
    }
    assert.notEqual(f.run().status,0);
    assert.equal(existsSync(f.output),false);
    f.noStage();
  });

for (const kind of ["file","directory","symlink","dangling"])
  test(`never replace existing ${kind}`, async t => {
    const f = await fixture(t);
    if(kind === "file") writeFileSync(f.output,"preserve");
    else if(kind === "directory") mkdirSync(f.output);
    else symlinkSync(kind === "symlink" ? f.home : join(f.root,"missing"),f.output);
    assert.notEqual(f.run().status,0);
    assert.deepEqual(f.calls(),[]);
    f.noStage();
  });

test("help and invalid arguments do not build", async t => {
  const f = await fixture(t);
  assert.equal(f.run(["--help"]).status,0);
  for(const args of [[""],["one","two"],["--unknown"],["--team-id",team],["--sign-identity","-"],
    ["bad\npath"],[f.output,...signing,"--team-id",team]]) assert.notEqual(f.run(args).status,0);
  assert.deepEqual(f.calls(),[]);
});

test("formatter-wrapped finite native constants remain readable", async t => {
  const f = await fixture(t);
  writeFileSync(f.native,readFileSync(f.native,"utf8").replaceAll(' = "',' =\n    "'));
  const result = f.run();
  assert.equal(result.status,0,result.stderr);
  assert.match(result.stdout,/Built Code comparison preview/);
  f.noStage();
});
