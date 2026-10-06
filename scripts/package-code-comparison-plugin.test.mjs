import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import { constants } from "node:fs";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { MAX_FILE_BYTES, PACKAGE_MANIFEST, PLUGIN_FILES, PackageError,
  packPlugin, verifyPackage, runCLI } from "./package-code-comparison-plugin.mjs";

const VERSION = "0.0.2";
const MARKETPLACE = "quotatempo-code-12345678-1234-4234-8234-123456789abc";
const sha256 = bytes => createHash("sha256").update(bytes).digest("hex");
const encode = value => `${JSON.stringify(value, null, 2)}\n`;
const code = expected => error => error.code === expected;

async function fixture(t) {
  // macOS tmpdir() can contain /var, a symlink; fixtures use its real directory.
  const root = await fs.mkdtemp(join(await fs.realpath(tmpdir()), "quotatempo-package-test-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await fs.chmod(root, 0o700);
  const source = join(root, "synthetic-source");
  const destination = join(root, "package");
  await fs.mkdir(source, { mode: 0o700 });
  await fs.mkdir(join(source, ".claude-plugin"), { mode: 0o700 });
  await fs.mkdir(join(source, "hooks"), { mode: 0o700 });
  const bytes = {
    ".claude-plugin/plugin.json": encode({ name: "quotatempo-usage-probe", version: VERSION,
      author: { name: "Synthetic fixture" } }),
    ".claude-plugin/marketplace.json": encode({ name: "quotatempo-local-probe",
      owner: { name: "Synthetic fixture" }, metadata: { version: VERSION, description: "Fixture" },
      plugins: [{ name: "quotatempo-usage-probe", source: "./", version: VERSION }] }),
    "hooks/hooks.json": encode({ modules: ["./register.mjs"] }),
    "hooks/register.mjs": "throw new Error('synthetic fixture must not execute');\n",
    "producer.mjs": "// Synthetic producer, not imported.\n",
    "protocol.mjs": "// Synthetic protocol, not imported.\n",
    "transport-crypto.mjs": "// Synthetic crypto, not imported.\n",
    "THIRD_PARTY_NOTICES.txt": "Synthetic test notice.\n",
  };
  for (const [path, value] of Object.entries(bytes)) {
    await fs.writeFile(join(source, path), value, { mode: 0o600 });
  }
  return { root, source, destination, bytes };
}
async function packaged(t, marketplaceName = MARKETPLACE) {
  const value = await fixture(t);
  value.result = await packPlugin({ ...value, marketplaceName });
  return value;
}
async function editJSON(path, edit) {
  const value = JSON.parse(await fs.readFile(path, "utf8"));
  edit(value);
  await fs.writeFile(path, encode(value));
}
async function refreshHash(destination, path) {
  const bytes = await fs.readFile(join(destination, path));
  await editJSON(join(destination, PACKAGE_MANIFEST), manifest => { manifest.files[path] = sha256(bytes); });
}

test("copies the exact allowlist, isolates marketplace, verifies version, identity and digest", async t => {
  const { source, destination, bytes, result } = await packaged(t);
  assert.equal(result.version, VERSION);
  assert.equal(result.marketplaceName, MARKETPLACE);
  assert.equal(result.pluginID, `quotatempo-usage-probe@${MARKETPLACE}`);
  assert.equal(result.destination, destination);
  assert.equal(result.packageDigest, sha256(await fs.readFile(join(destination, PACKAGE_MANIFEST))));
  assert.deepEqual(await verifyPackage(destination), result);
  assert.deepEqual(Object.keys(result.manifest).sort(), ["files", "purpose", "releaseVersion", "schemaVersion"]);
  assert.equal(result.manifest.schemaVersion, 1);
  assert.equal(result.manifest.purpose, "quotatempo-code-comparison-plugin");
  assert.equal(result.manifest.releaseVersion, VERSION);
  assert.deepEqual(Object.keys(result.manifest.files), PLUGIN_FILES);
  assert.deepEqual((await fs.readdir(destination)).sort(),
    [".claude-plugin", "hooks", "producer.mjs", "protocol.mjs", "transport-crypto.mjs", "THIRD_PARTY_NOTICES.txt", PACKAGE_MANIFEST].sort());
  for (const path of PLUGIN_FILES) {
    const copy = await fs.readFile(join(destination, path));
    assert.equal(result.manifest.files[path], sha256(copy));
    if (path !== ".claude-plugin/marketplace.json") assert.deepEqual(copy, Buffer.from(bytes[path]));
    assert.equal(await fs.readFile(join(source, path), "utf8"), bytes[path], "Source stays unchanged");
  }
  const before = JSON.parse(bytes[".claude-plugin/marketplace.json"]);
  const after = JSON.parse(await fs.readFile(join(destination, ".claude-plugin/marketplace.json"), "utf8"));
  assert.deepEqual(after, { ...before, name: MARKETPLACE });
  for (const path of [destination, join(destination, ".claude-plugin"), join(destination, "hooks")]) {
    const info = await fs.lstat(path);
    assert.equal(info.mode & 0o7777, 0o700);
    assert.equal(info.uid, process.getuid());
  }
  for (const path of [...PLUGIN_FILES, PACKAGE_MANIFEST]) {
    const info = await fs.lstat(join(destination, path));
    assert.equal(info.mode & 0o7777, 0o600);
    assert.equal(info.uid, process.getuid());
    assert.equal(info.nlink, 1);
  }
  await assert.rejects(fs.lstat(join(destination, "package.json")), code("ENOENT"));
});

test("default names are fresh lowercase UUIDv4 marketplaces and never reuse trial identity", async t => {
  const { source, root, destination } = await fixture(t);
  const first = await packPlugin({ source, destination });
  const second = await packPlugin({ source, destination: join(root, "second-package") });
  const pattern = /^quotatempo-code-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  assert.match(first.marketplaceName, pattern);
  assert.match(second.marketplaceName, pattern);
  assert.notEqual(first.marketplaceName, second.marketplaceName);
  assert.notEqual(first.packageDigest, second.packageDigest);
});

for (const marketplaceName of ["quotatempo-local-probe", "", "quotatempo-code-12345678-1234-5234-8234-123456789abc",
  "quotatempo-code-12345678-1234-4234-7234-123456789abc", MARKETPLACE.toUpperCase(), `${MARKETPLACE}\n`, null]) {
  test(`rejects invalid marketplace name ${JSON.stringify(marketplaceName)}`, async t => {
    const value = await fixture(t);
    await assert.rejects(packPlugin({ ...value, marketplaceName }), code("invalid_marketplace_name"));
    await assert.rejects(fs.lstat(value.destination), code("ENOENT"));
  });
}

test("ignores excluded source entries without reading, traversing or copying them", async t => {
  const { source, destination, root } = await fixture(t);
  for (const path of ["README.md", "receiver.mjs", "observe.mjs", "producer.test.mjs", "package.json"]) {
    await fs.symlink(join(root, "nonexistent-unrelated"), join(source, path));
  }
  await fs.mkdir(join(source, "tests"));
  const reads = [];
  const io = { ...fs, open: async (path, ...args) => {
    if (path.startsWith(`${source}/`)) reads.push(path.slice(source.length + 1));
    return fs.open(path, ...args);
  } };
  await packPlugin({ source, destination }, io);
  assert.deepEqual(reads, PLUGIN_FILES);
});

for (const kind of ["directory", "regular-file", "symlink", "dangling-symlink"]) {
  test(`refuses existing destination (${kind}) without modification`, async t => {
    const { source, destination, root } = await fixture(t);
    if (kind === "directory") {
      await fs.mkdir(destination, { mode: 0o700 });
      await fs.writeFile(join(destination, "sentinel"), "keep");
    } else if (kind === "regular-file") await fs.writeFile(destination, "keep");
    else await fs.symlink(kind === "symlink" ? source : join(root, "missing"), destination);
    const before = await fs.lstat(destination);
    await assert.rejects(packPlugin({ source, destination }), code("destination_exists"));
    assert.equal((await fs.lstat(destination)).ino, before.ino);
    if (kind === "directory") assert.equal(await fs.readFile(join(destination, "sentinel"), "utf8"), "keep");
    if (kind === "regular-file") assert.equal(await fs.readFile(destination, "utf8"), "keep");
  });
}

for (const component of ["source-root", "source-parent", ".claude-plugin", "hooks", "destination-parent"]) {
  test(`rejects symlink directory component ${component}`, async t => {
    const value = await fixture(t);
    const alias = join(value.root, "alias");
    if (component === "source-root") {
      await fs.symlink(value.source, alias);
      value.source = alias;
    } else if (component === "source-parent") {
      await fs.symlink(value.root, alias);
      value.source = join(alias, "synthetic-source");
    } else if (component === "destination-parent") {
      await fs.symlink(value.root, alias);
      value.destination = join(alias, "package");
    } else {
      await fs.rename(join(value.source, component), alias);
      await fs.symlink(alias, join(value.source, component));
    }
    await assert.rejects(packPlugin(value), code("symlink_rejected"));
    await assert.rejects(fs.lstat(join(value.root, "package")), code("ENOENT"));
  });
}

for (const kind of ["symlink", "hardlink", "directory", "oversize", "missing"]) {
  test(`rejects unsafe source file (${kind}) before destination creation`, async t => {
    const value = await fixture(t);
    const path = join(value.source, "producer.mjs");
    const other = join(value.root, "other");
    await fs.writeFile(other, "untouched");
    if (kind === "oversize") await fs.truncate(path, MAX_FILE_BYTES + 1);
    else {
      await fs.unlink(path);
      if (kind === "symlink") await fs.symlink(other, path);
      if (kind === "hardlink") await fs.link(other, path);
      if (kind === "directory") await fs.mkdir(path);
    }
    await assert.rejects(packPlugin(value), code({ symlink: "symlink_rejected", hardlink: "nonregular_file_rejected",
      directory: "nonregular_file_rejected", oversize: "oversize_file_rejected", missing: "ENOENT" }[kind]));
    await assert.rejects(fs.lstat(value.destination), code("ENOENT"));
    assert.equal(await fs.readFile(other, "utf8"), "untouched");
  });
}

for (const mutation of ["plugin-name", "marketplace-plugin-name", "metadata-version", "entry-version", "invalid-version", "multiple-plugins"]) {
  test(`checks fixed plugin identity and matching version (${mutation})`, async t => {
    const value = await fixture(t);
    const plugin = mutation === "plugin-name" || mutation === "invalid-version";
    const path = join(value.source, PLUGIN_FILES[plugin ? 0 : 1]);
    await editJSON(path, data => {
      if (mutation === "plugin-name") data.name = "other-plugin";
      if (mutation === "invalid-version") data.version = "latest";
      if (mutation === "marketplace-plugin-name") data.plugins[0].name = "other-plugin";
      if (mutation === "metadata-version") data.metadata.version = "0.0.3";
      if (mutation === "entry-version") data.plugins[0].version = "0.0.3";
      if (mutation === "multiple-plugins") data.plugins.push({ ...data.plugins[0] });
    });
    await assert.rejects(packPlugin(value), error => error instanceof PackageError);
    await assert.rejects(fs.lstat(value.destination), code("ENOENT"));
  });
}

test("marketplace entry version is optional; metadata version remains required", async t => {
  const value = await fixture(t);
  await editJSON(join(value.source, PLUGIN_FILES[1]), data => { delete data.plugins[0].version; });
  assert.equal((await packPlugin(value)).version, VERSION);
});

test("paths must be explicit, absolute, non-traversing and have an existing parent", async t => {
  const value = await fixture(t);
  await assert.rejects(packPlugin({ destination: value.destination }), code("absolute_path_required"));
  await assert.rejects(packPlugin({ source: value.source }), code("absolute_path_required"));
  await assert.rejects(packPlugin({ ...value, destination: "relative" }), code("absolute_path_required"));
  await assert.rejects(packPlugin({ ...value, source: `${value.source}/../synthetic-source` }), code("invalid_path"));
  await assert.rejects(packPlugin({ ...value, destination: join(value.root, "missing-parent", "package") }), code("ENOENT"));
  await assert.rejects(verifyPackage("relative"), code("absolute_path_required"));
  await assert.rejects(fs.lstat(value.destination), code("ENOENT"));
});

test("allows sticky ancestors while enforcing private package root", async t => {
  const value = await fixture(t);
  const sticky = join(value.root, "sticky-parent");
  await fs.mkdir(sticky);
  await fs.chmod(sticky, 0o1777);
  value.destination = join(sticky, "package");
  const result = await packPlugin(value);
  assert.deepEqual(await verifyPackage(value.destination), result);
  assert.equal((await fs.lstat(sticky)).mode & 0o7777, 0o1777);
});

for (const extra of ["unexpected.txt", "tests", "hooks/extra.mjs", ".claude-plugin/extra.json", "package.json"]) {
  test(`read-only verification rejects and preserves unknown entry ${extra}`, async t => {
    const { destination } = await packaged(t);
    const path = join(destination, extra);
    if (extra === "tests") await fs.mkdir(path);
    else await fs.writeFile(path, "preserve");
    await assert.rejects(verifyPackage(destination), code("unexpected_package_entries"));
    assert.equal((await fs.lstat(path)).isDirectory(), extra === "tests");
    if (extra !== "tests") assert.equal(await fs.readFile(path, "utf8"), "preserve");
  });
}

test("verification never invokes write, remove or other mutation methods", async t => {
  const { destination, result } = await packaged(t);
  const io = { lstat: fs.lstat, readdir: fs.readdir, open: async (path, flags) => {
    assert.equal(flags, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const handle = await fs.open(path, flags);
    return { stat: handle.stat.bind(handle), read: handle.read.bind(handle), close: handle.close.bind(handle) };
  } };
  assert.deepEqual(await verifyPackage(destination, io), result);
});

for (const relative of ["", ".claude-plugin", "hooks", ...PLUGIN_FILES, PACKAGE_MANIFEST]) {
  test(`verification rejects non-owner-only permissions: ${relative || "root"}`, async t => {
    const { destination } = await packaged(t);
    const directory = ["", ".claude-plugin", "hooks"].includes(relative);
    await fs.chmod(join(destination, relative), directory ? 0o755 : 0o644);
    await assert.rejects(verifyPackage(destination), code("unsafe_permissions"));
  });
}

test("verification rejects different owner via synthetic metadata", async t => {
  const { destination } = await packaged(t);
  const io = { ...fs, lstat: async path => {
    const info = await fs.lstat(path);
    if (path !== destination) return info;
    return new Proxy(info, { get(target, key) {
      if (key === "uid") return target.uid + 1;
      const value = target[key];
      return typeof value === "function" ? value.bind(target) : value;
    } });
  } };
  await assert.rejects(verifyPackage(destination, io), code("unsafe_permissions"));
});

for (const relative of ["", ".claude-plugin", "hooks", "producer.mjs", PACKAGE_MANIFEST]) {
  test(`verification rejects package symlink: ${relative || "root"}`, async t => {
    const { root, destination } = await packaged(t);
    const path = join(destination, relative);
    const moved = join(root, "moved");
    await fs.rename(path, moved);
    await fs.symlink(moved, path);
    await assert.rejects(verifyPackage(destination), code("symlink_rejected"));
    assert.equal((await fs.lstat(path)).isSymbolicLink(), true);
  });
}

for (const relative of ["producer.mjs", PACKAGE_MANIFEST]) {
  test(`verification rejects package hardlink: ${relative}`, async t => {
    const { root, destination } = await packaged(t);
    await fs.link(join(destination, relative), join(root, "second-link"));
    await assert.rejects(verifyPackage(destination), code("nonregular_file_rejected"));
  });
}

for (const relative of ["producer.mjs", PACKAGE_MANIFEST]) {
  test(`verification rejects oversized package file: ${relative}`, async t => {
    const { destination } = await packaged(t);
    await fs.truncate(join(destination, relative), MAX_FILE_BYTES + 1);
    await assert.rejects(verifyPackage(destination), code("oversize_file_rejected"));
  });
}

test("verification detects file byte tampering", async t => {
  const { destination } = await packaged(t);
  await fs.appendFile(join(destination, "producer.mjs"), "// tampered\n");
  await assert.rejects(verifyPackage(destination), code("hash_mismatch"));
});

for (const mutation of ["schema", "purpose", "extra-key", "extra-file", "missing-file", "bad-hash", "version"]) {
  test(`verification strictly validates manifest (${mutation})`, async t => {
    const { destination } = await packaged(t);
    await editJSON(join(destination, PACKAGE_MANIFEST), data => {
      if (mutation === "schema") data.schemaVersion = 2;
      if (mutation === "purpose") data.purpose = "other";
      if (mutation === "extra-key") data.trusted = true;
      if (mutation === "extra-file") data.files["receiver.mjs"] = "0".repeat(64);
      if (mutation === "missing-file") delete data.files["producer.mjs"];
      if (mutation === "bad-hash") data.files["producer.mjs"] = "not-a-sha256";
      if (mutation === "version") data.releaseVersion = "0.0.3";
    });
    await assert.rejects(verifyPackage(destination), code(mutation === "version" ? "version_mismatch" : "invalid_package_manifest"));
  });
}

test("verification validates marketplace namespace even when hashes are recomputed", async t => {
  const { destination } = await packaged(t);
  await editJSON(join(destination, PLUGIN_FILES[1]), data => { data.name = "quotatempo-local-probe"; });
  await refreshHash(destination, PLUGIN_FILES[1]);
  await assert.rejects(verifyPackage(destination), code("invalid_marketplace_name"));
});

test("verification rechecks metadata versions even when hashes are recomputed", async t => {
  const { destination } = await packaged(t);
  await editJSON(join(destination, PLUGIN_FILES[1]), data => { data.metadata.version = "0.0.3"; });
  await refreshHash(destination, PLUGIN_FILES[1]);
  await assert.rejects(verifyPackage(destination), code("version_mismatch"));
});

test("manifest byte digest is a receipt pin, not a signature or trust claim", async t => {
  const { destination, result } = await packaged(t);
  await fs.appendFile(join(destination, PACKAGE_MANIFEST), "\n");
  const changed = await verifyPackage(destination);
  assert.deepEqual(changed.manifest, result.manifest);
  assert.notEqual(changed.packageDigest, result.packageDigest);
  assert.equal(changed.packageDigest, sha256(await fs.readFile(join(destination, PACKAGE_MANIFEST))));
});

test("cleans partial exclusive writes and only directories created by this call", async t => {
  const value = await fixture(t);
  const io = { ...fs, open: async (path, flags, mode) => {
    const handle = await fs.open(path, flags, mode);
    if (path !== join(value.destination, "producer.mjs") || !(flags & constants.O_CREAT)) return handle;
    return { stat: handle.stat.bind(handle), close: handle.close.bind(handle),
      writeFile: async () => { await handle.writeFile("partial"); throw new Error("synthetic write failure"); } };
  } };
  await assert.rejects(packPlugin(value, io), error => error.code === "package_io_failed" && !error.cleanupIncomplete);
  await assert.rejects(fs.lstat(value.destination), code("ENOENT"));
  assert.equal(await fs.readFile(join(value.source, "producer.mjs"), "utf8"), value.bytes["producer.mjs"]);
  assert.equal((await fs.lstat(value.root)).isDirectory(), true);
});

test("preserves foreign files encountered during failure and reports incomplete cleanup", async t => {
  const value = await fixture(t);
  const target = join(value.destination, "producer.mjs");
  const io = { ...fs, open: async (path, flags, mode) => {
    if (path === target && (flags & constants.O_CREAT)) await fs.writeFile(target, "foreign", { mode: 0o600 });
    return fs.open(path, flags, mode);
  } };
  await assert.rejects(packPlugin(value, io), error => error.code === "destination_exists" && error.cleanupIncomplete);
  assert.equal(await fs.readFile(target, "utf8"), "foreign");
  assert.deepEqual(await fs.readdir(value.destination), ["producer.mjs"]);
});

test("preserves inode-substituted files instead of deleting another actor's replacement", async t => {
  const value = await fixture(t);
  const owned = join(value.destination, "hooks/register.mjs");
  const io = { ...fs, open: async (path, flags, mode) => {
    if (path === join(value.destination, "producer.mjs") && (flags & constants.O_CREAT)) {
      await fs.rename(owned, join(value.root, "detached-owned-file"));
      await fs.writeFile(owned, "foreign replacement", { mode: 0o600 });
      throw new Error("synthetic failure");
    }
    return fs.open(path, flags, mode);
  } };
  await assert.rejects(packPlugin(value, io), error => error.cleanupIncomplete);
  assert.equal(await fs.readFile(owned, "utf8"), "foreign replacement");
});

test("cleanup does not follow a substituted directory symlink", async t => {
  const value = await fixture(t);
  const external = join(value.root, "foreign-directory");
  await fs.mkdir(external);
  await fs.writeFile(join(external, "register.mjs"), "foreign");
  const io = { ...fs, open: async (path, flags, mode) => {
    if (path === join(value.destination, "producer.mjs") && (flags & constants.O_CREAT)) {
      await fs.rename(join(value.destination, "hooks"), join(value.root, "detached-hooks"));
      await fs.symlink(external, join(value.destination, "hooks"));
      throw new Error("synthetic failure");
    }
    return fs.open(path, flags, mode);
  } };
  await assert.rejects(packPlugin(value, io), error => error.cleanupIncomplete);
  assert.equal(await fs.readFile(join(external, "register.mjs"), "utf8"), "foreign");
  assert.equal((await fs.lstat(join(value.destination, "hooks"))).isSymbolicLink(), true);
});

test("detects an earlier file changing while verification reads a later file", async t => {
  const { destination } = await packaged(t);
  const io = { ...fs, open: async (path, ...args) => {
    if (path === join(destination, "protocol.mjs")) {
      await fs.appendFile(join(destination, "producer.mjs"), "// concurrent modification\n");
    }
    return fs.open(path, ...args);
  } };
  await assert.rejects(verifyPackage(destination, io), code("concurrent_change"));
});

test("detects source changes during collection without creating a destination", async t => {
  const value = await fixture(t);
  const io = { ...fs, open: async (path, ...args) => {
    if (path === join(value.source, "protocol.mjs")) {
      await fs.appendFile(join(value.source, "producer.mjs"), "// concurrent modification\n");
    }
    return fs.open(path, ...args);
  } };
  await assert.rejects(packPlugin(value, io), code("concurrent_change"));
  await assert.rejects(fs.lstat(value.destination), code("ENOENT"));
});

test("CLI pack and verify emit only requested metadata", async t => {
  const { source, destination } = await fixture(t);
  const first = await runCLI(["pack", "--source", source, "--destination", destination,
    "--marketplace-name", MARKETPLACE]);
  assert.deepEqual(Object.keys(first), ["destination", "version", "pluginID", "packageDigest"]);
  assert.equal(first.version, VERSION);
  assert.equal(first.pluginID, `quotatempo-usage-probe@${MARKETPLACE}`);
  assert.equal(first.packageDigest, sha256(await fs.readFile(join(destination, PACKAGE_MANIFEST))));
  assert.deepEqual(await runCLI(["verify", "--directory", destination]), first);
});

for (const args of [[], ["unknown"], ["pack"], ["verify"], ["verify", "--directory"],
  ["pack", "--source", "--destination", "value"], ["verify", "--unknown", "value"],
  ["verify", "--directory", "/ignored", "--source", "/ignored"],
  ["verify", "--directory", "/ignored", "--directory", "/ignored"],
  ["pack", "--source", "/ignored", "--destination", "/ignored", "--destination", "/ignored"],
  ["verify", "--directory", "/ignored", "extra"]]) {
  test(`CLI rejects malformed arguments without filesystem access: ${JSON.stringify(args)}`, async () => {
    const noIO = new Proxy({}, { get() { assert.fail("Invalid arguments must not reach filesystem"); } });
    const result = await runCLI(args, noIO);
    assert.deepEqual(Object.keys(result), ["error", "cleanupIncomplete"]);
    assert(["invalid_argument", "missing_argument"].includes(result.error));
    assert.equal(result.cleanupIncomplete, false);
  });
}

test("CLI sanitizes raw exceptions and reports incomplete cleanup without details", async t => {
  const value = await fixture(t);
  const io = { ...fs, lstat: async () => { throw new Error("PRIVATE synthetic diagnostic must not escape"); } };
  assert.deepEqual(await runCLI(["verify", "--directory", value.destination], io),
    { error: "package_io_failed", cleanupIncomplete: false });
  const failureIO = { ...fs, open: async (path, flags, mode) => {
    if (path === join(value.destination, "producer.mjs") && (flags & constants.O_CREAT)) {
      await fs.writeFile(path, "foreign", { mode: 0o600 });
    }
    return fs.open(path, flags, mode);
  } };
  assert.deepEqual(await runCLI(["pack", "--source", value.source, "--destination", value.destination], failureIO),
    { error: "destination_exists", cleanupIncomplete: true });
});

test("direct Node CLI uses JSON stdout/stderr and exit status; import has no side effects", async t => {
  const { source, destination, root } = await fixture(t);
  const script = fileURLToPath(new URL("./package-code-comparison-plugin.mjs", import.meta.url));
  const invoke = args => spawnSync(process.execPath, [script, ...args], { encoding: "utf8", cwd: root, timeout: 10_000 });
  const imported = spawnSync(process.execPath, ["--input-type=module", "-e",
    `await import(${JSON.stringify(new URL("./package-code-comparison-plugin.mjs", import.meta.url).href)});`],
  { encoding: "utf8", cwd: root, timeout: 10_000 });
  assert.equal(imported.status, 0);
  assert.equal(imported.stdout, "");
  assert.equal(imported.stderr, "");
  await assert.rejects(fs.lstat(destination), code("ENOENT"));
  const pack = invoke(["pack", "--source", source, "--destination", destination]);
  assert.equal(pack.status, 0, pack.stderr);
  assert.equal(pack.stderr, "");
  const result = JSON.parse(pack.stdout);
  assert.deepEqual(Object.keys(result), ["destination", "version", "pluginID", "packageDigest"]);
  const verify = invoke(["verify", "--directory", destination]);
  assert.equal(verify.status, 0, verify.stderr);
  assert.equal(verify.stderr, "");
  assert.deepEqual(JSON.parse(verify.stdout), result);
  const duplicate = invoke(["pack", "--source", source, "--destination", destination]);
  assert.equal(duplicate.status, 1);
  assert.equal(duplicate.stdout, "");
  assert.deepEqual(JSON.parse(duplicate.stderr), { error: "destination_exists", cleanupIncomplete: false });
  const bad = invoke(["verify", "--directory", join(root, "not-present")]);
  assert.equal(bad.status, 1);
  assert.equal(bad.stdout, "");
  assert.deepEqual(JSON.parse(bad.stderr), { error: "package_io_failed", cleanupIncomplete: false });
});

for (const relative of [".claude-plugin/plugin.json", ".claude-plugin/marketplace.json"]) {
  test(`malformed source JSON is rejected without destination: ${relative}`, async t => {
    const value = await fixture(t);
    await fs.writeFile(join(value.source, relative), "{malformed");
    await assert.rejects(packPlugin(value), code(relative.endsWith("/plugin.json")
      ? "invalid_plugin_metadata" : "invalid_marketplace_metadata"));
    await assert.rejects(fs.lstat(value.destination), code("ENOENT"));
  });
}

for (const bytes of [Buffer.from("{malformed"), Buffer.from([0xff, 0xfe])]) {
  test(`verification rejects malformed manifest JSON/UTF-8 (${bytes.toString("hex")})`, async t => {
    const { destination } = await packaged(t);
    await fs.writeFile(join(destination, PACKAGE_MANIFEST), bytes);
    await assert.rejects(verifyPackage(destination), code("invalid_package_manifest"));
  });
}

test("bounded readers correctly handle short filesystem reads", async t => {
  const value = await fixture(t);
  const io = { ...fs, open: async (path, flags, mode) => {
    const handle = await fs.open(path, flags, mode);
    if (flags & constants.O_CREAT) return handle;
    return { stat: handle.stat.bind(handle), close: handle.close.bind(handle),
      read: (buffer, offset, length, position) => handle.read(buffer, offset, Math.min(length, 7), position) };
  } };
  const result = await packPlugin(value, io);
  assert.deepEqual(await verifyPackage(value.destination, io), result);
});

test("mkdir race preserves the entire pre-existing competing destination", async t => {
  const value = await fixture(t);
  const io = { ...fs, mkdir: async (path, options) => {
    if (path === value.destination) {
      await fs.mkdir(path, { mode: 0o700 });
      await fs.writeFile(join(path, "sentinel"), "foreign");
    }
    return fs.mkdir(path, options);
  } };
  await assert.rejects(packPlugin(value, io), error => error.code === "destination_exists" && !error.cleanupIncomplete);
  assert.deepEqual(await fs.readdir(value.destination), ["sentinel"]);
  assert.equal(await fs.readFile(join(value.destination, "sentinel"), "utf8"), "foreign");
});

test("subdirectory creation failure cleans only the owned empty root", async t => {
  const value = await fixture(t);
  const io = { ...fs, mkdir: async (path, options) => {
    if (path === join(value.destination, "hooks")) throw new Error("synthetic mkdir failure");
    return fs.mkdir(path, options);
  } };
  await assert.rejects(packPlugin(value, io), error => error.code === "package_io_failed" && !error.cleanupIncomplete);
  await assert.rejects(fs.lstat(value.destination), code("ENOENT"));
});

test("failed post-creation identity check reports incomplete cleanup without blind deletion", async t => {
  const value = await fixture(t);
  let created = false;
  const io = { ...fs, mkdir: async (path, options) => {
    await fs.mkdir(path, options);
    if (path === value.destination) created = true;
  }, lstat: async path => {
    if (created && path === value.destination) throw new Error("synthetic stat failure");
    return fs.lstat(path);
  } };
  await assert.rejects(packPlugin(value, io), error => error.code === "package_io_failed" && error.cleanupIncomplete);
  assert.deepEqual(await fs.readdir(value.destination), []);
});
