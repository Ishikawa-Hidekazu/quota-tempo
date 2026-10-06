// Explicit isolated official-runtime acceptance. Never installs into real HOME.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { PLUGIN_FILES } from "./package-code-comparison-plugin.mjs";

const [option, executable, extra] = process.argv.slice(2);
assert.equal(option, "--cli");
assert.equal(extra, undefined);
assert.ok(path.isAbsolute(executable));
const binary = fs.lstatSync(executable);
assert.ok(binary.isFile() && !binary.isSymbolicLink() && (binary.mode & 0o022) === 0);
assert.equal(crypto.createHash("sha256").update(fs.readFileSync(executable)).digest("hex"),
  "03d66745e3bb69ec727d66023696f3820bc0a00a8a5ba725eb6706d0c67cbe69");
assert.equal(spawnSync("/usr/bin/codesign", ["--verify", "--strict", executable],
  { stdio: "ignore", timeout: 15000 }).status, 0);
const root = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), "qtc-mods-test-"));
fs.chmodSync(root, 0o700);
try {
  const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../experiments/claude-mods-usage");
  const plugin = path.join(root, "plugin");
  for (const relative of [...PLUGIN_FILES, "tests/runtime.test.ts", "tests/crypto-fixture.mjs"]) {
    const target = path.join(plugin, relative);
    fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
    fs.copyFileSync(path.join(source, relative), target);
    fs.chmodSync(target, 0o600);
  }
  for (const name of ["home", "tmp", "project"]) fs.mkdirSync(path.join(root, name), { mode: 0o700 });
  const policy = `(version 1) (allow default) (deny network*)
    (deny file-read* file-write* (subpath ${JSON.stringify(os.homedir())}))`;
  const environment = { HOME: path.join(root, "home"), TMPDIR: path.join(root, "tmp"),
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LANG: "en_US.UTF-8" };
  for (const action of ["validate", "test"]) {
    const result = spawnSync("/usr/bin/sandbox-exec", ["-p", policy, executable, "plugin", action, plugin],
      { cwd: path.join(root, "project"), env: environment, encoding: "utf8", timeout: 120000,
        maxBuffer: 256 * 1024 });
    // Output contains synthetic fixture assertions only; no real home or network is accessible.
    if (result.status !== 0) {
      process.stderr.write((result.stdout ?? "").slice(-4000));
      process.stderr.write((result.stderr ?? "").slice(-4000));
      throw new Error(`isolated_plugin_${action}_failed`);
    }
    process.stdout.write(result.stdout.slice(-3000));
  }
  console.log(JSON.stringify({ status: "passed", networkAllowed: false, normalHomeAllowed: false,
    providerRequests: 0, nativeAcceptance: false }));
} finally {
  const stat = fs.lstatSync(root);
  assert.ok(stat.isDirectory() && !stat.isSymbolicLink() && stat.uid === process.getuid()
    && (stat.mode & 0o777) === 0o700);
  fs.rmSync(root, { recursive: true });
}
