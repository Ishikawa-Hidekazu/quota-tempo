#!/usr/bin/env node
import * as fs from "node:fs/promises";
import { constants } from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import { dirname, isAbsolute, join, parse, resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const PLUGIN_FILES = Object.freeze([
  ".claude-plugin/plugin.json",
  ".claude-plugin/marketplace.json",
  "hooks/hooks.json",
  "hooks/register.mjs",
  "producer.mjs",
  "protocol.mjs",
  "transport-crypto.mjs",
  "THIRD_PARTY_NOTICES.txt",
]);
export const PACKAGE_MANIFEST = "quotatempo-package.json";
export const MAX_FILE_BYTES = 256 * 1024;
const MAX_MANIFEST_BYTES = 16 * 1024;
const DIRECTORIES = Object.freeze([".claude-plugin", "hooks"]);
const PURPOSE = "quotatempo-code-comparison-plugin";
const PLUGIN_NAME = "quotatempo-usage-probe";
const MARKETPLACE_PATTERN = /^quotatempo-code-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

export class PackageError extends Error {
  constructor(code, { cleanupIncomplete = false } = {}) {
    super(code);
    this.name = "PackageError";
    this.code = code;
    this.cleanupIncomplete = cleanupIncomplete;
  }
}
function fail(code) { throw new PackageError(code); }
function object(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
function exactKeys(value, keys) {
  return object(value) && Object.keys(value).length === keys.length
    && keys.every(key => Object.hasOwn(value, key));
}
function absolute(value) {
  if (typeof value !== "string" || !isAbsolute(value)) fail("absolute_path_required");
  if (/[\x00-\x1f\x7f\\]/.test(value) || value.split("/").some(part => part === "." || part === "..")) {
    fail("invalid_path");
  }
  return resolve(value);
}
function identity(a, b) { return a.dev === b.dev && a.ino === b.ino; }
function sameDirectory(a, b) {
  return b.isDirectory() && identity(a, b) && a.mode === b.mode && a.uid === b.uid;
}
function sameFile(a, b) {
  return b.isFile() && identity(a, b) && a.size === b.size && a.mode === b.mode
    && a.uid === b.uid && a.nlink === b.nlink && a.mtimeMs === b.mtimeMs && a.ctimeMs === b.ctimeMs;
}
function privateEntry(info, mode) {
  if (typeof process.getuid !== "function") fail("owner_check_unavailable");
  if (info.uid !== process.getuid() || (info.mode & 0o7777) !== mode) fail("unsafe_permissions");
}
async function directoryChain(path, io) {
  let current = parse(path).root;
  const paths = [current];
  for (const part of path.slice(current.length).split("/").filter(Boolean)) {
    current = join(current, part);
    paths.push(current);
  }
  const chain = [];
  for (const entry of paths) {
    const info = await io.lstat(entry);
    if (info.isSymbolicLink()) fail("symlink_rejected");
    if (!info.isDirectory()) fail("non_directory_rejected");
    chain.push({ path: entry, info });
  }
  return chain;
}
async function unchangedDirectories(chain, io) {
  for (const entry of chain) {
    if (!sameDirectory(entry.info, await io.lstat(entry.path))) fail("concurrent_change");
  }
}
async function missing(path, io) {
  try { await io.lstat(path); } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }
  fail("destination_exists");
}
async function readRegular(path, limit, io, ownerOnly = false) {
  const chain = await directoryChain(dirname(path), io);
  const before = await io.lstat(path);
  if (before.isSymbolicLink()) fail("symlink_rejected");
  if (!before.isFile() || before.nlink !== 1) fail("nonregular_file_rejected");
  if (before.size > limit) fail("oversize_file_rejected");
  if (ownerOnly) privateEntry(before, 0o600);
  const handle = await io.open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const opened = await handle.stat();
    if (!sameFile(before, opened)) fail("concurrent_change");
    const buffer = Buffer.alloc(limit + 1);
    let length = 0;
    while (length < buffer.length) {
      const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length);
      if (bytesRead === 0) break;
      length += bytesRead;
    }
    if (length > limit) fail("oversize_file_rejected");
    if (length !== before.size || !sameFile(opened, await handle.stat())
      || !sameFile(opened, await io.lstat(path))) fail("concurrent_change");
    await unchangedDirectories(chain, io);
    return { bytes: buffer.subarray(0, length), info: opened, path, chain };
  } finally { await handle.close(); }
}
async function unchangedFiles(records, io) {
  for (const record of records) {
    await unchangedDirectories(record.chain, io);
    if (!sameFile(record.info, await io.lstat(record.path))) fail("concurrent_change");
  }
}
function json(bytes, code) {
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
  catch { fail(code); }
}
function validVersion(value) {
  return typeof value === "string" && value.length <= 128 && value.trim() === value
    && /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(value);
}
function validMarketplaceName(value) {
  return typeof value === "string" && value.length === 52 && MARKETPLACE_PATTERN.test(value);
}
function metadataVersion(files, expected) {
  const plugin = json(files[PLUGIN_FILES[0]], "invalid_plugin_metadata");
  const marketplace = json(files[PLUGIN_FILES[1]], "invalid_marketplace_metadata");
  if (!object(plugin) || plugin.name !== PLUGIN_NAME
    || !validVersion(plugin.version)) fail("invalid_plugin_metadata");
  if (!object(marketplace) || !object(marketplace.metadata)
    || !validVersion(marketplace.metadata.version) || !Array.isArray(marketplace.plugins)
    || marketplace.plugins.length !== 1 || !object(marketplace.plugins[0])
    || marketplace.plugins[0].name !== plugin.name || marketplace.plugins[0].source !== "./") {
    fail("invalid_marketplace_metadata");
  }
  const entryVersion = marketplace.plugins[0].version;
  if (marketplace.metadata.version !== plugin.version
    || (entryVersion !== undefined && entryVersion !== plugin.version)
    || (expected !== undefined && (!validVersion(expected) || expected !== plugin.version))) {
    fail("version_mismatch");
  }
  return plugin.version;
}
function hash(bytes) { return createHash("sha256").update(bytes).digest("hex"); }
function manifestFor(files, releaseVersion) {
  return { schemaVersion: 1, purpose: PURPOSE, releaseVersion,
    files: Object.fromEntries(PLUGIN_FILES.map(path => [path, hash(files[path])])) };
}

async function exactInventory(destination, io) {
  const chain = await directoryChain(destination, io);
  // Ancestors such as /private/tmp may be shared/sticky; only the package is private.
  privateEntry(chain.at(-1).info, 0o700);
  async function entries(directory, expected) {
    const actual = await io.readdir(directory);
    if (actual.length !== expected.length || actual.some(name => !expected.includes(name))) {
      fail("unexpected_package_entries");
    }
  }
  await entries(destination, [...DIRECTORIES, ...PLUGIN_FILES.filter(file => dirname(file) === "."), PACKAGE_MANIFEST]);
  for (const directory of DIRECTORIES) {
    const path = join(destination, directory);
    const info = await io.lstat(path);
    if (info.isSymbolicLink()) fail("symlink_rejected");
    if (!info.isDirectory()) fail("non_directory_rejected");
    privateEntry(info, 0o700);
    await entries(path, PLUGIN_FILES.filter(file => dirname(file) === directory)
      .map(file => file.slice(directory.length + 1)));
    chain.push({ path, info });
  }
  await unchangedDirectories(chain, io);
  return chain;
}

// Hashes detect byte changes, not publisher trust or a cryptographic signature.
// This is read-only validation with change detection, not a filesystem lock.
// io is an optional filesystem seam for synthetic fault-injection tests.
export async function verifyPackage(directory, io = fs) {
  const destination = absolute(directory);
  const chain = await exactInventory(destination, io);
  const manifestRecord = await readRegular(join(destination, PACKAGE_MANIFEST), MAX_MANIFEST_BYTES, io, true);
  const manifest = json(manifestRecord.bytes, "invalid_package_manifest");
  if (!exactKeys(manifest, ["schemaVersion", "purpose", "releaseVersion", "files"])
    || manifest.schemaVersion !== 1 || manifest.purpose !== PURPOSE
    || !validVersion(manifest.releaseVersion) || !exactKeys(manifest.files, PLUGIN_FILES)
    || PLUGIN_FILES.some(path => typeof manifest.files[path] !== "string"
      || !/^[a-f0-9]{64}$/.test(manifest.files[path]))) fail("invalid_package_manifest");
  const files = {};
  const records = [manifestRecord];
  for (const path of PLUGIN_FILES) {
    const record = await readRegular(join(destination, path), MAX_FILE_BYTES, io, true);
    records.push(record);
    files[path] = record.bytes;
    if (hash(files[path]) !== manifest.files[path]) fail("hash_mismatch");
  }
  const version = metadataVersion(files, manifest.releaseVersion);
  const marketplaceName = json(files[PLUGIN_FILES[1]], "invalid_marketplace_metadata").name;
  if (!validMarketplaceName(marketplaceName)) fail("invalid_marketplace_name");
  await unchangedDirectories(chain, io);
  await exactInventory(destination, io);
  await unchangedFiles(records, io);
  return { version, marketplaceName, pluginID: `${PLUGIN_NAME}@${marketplaceName}`,
    packageDigest: hash(manifestRecord.bytes), destination, manifest };
}

async function cleanupCreated(created, parentChain, io) {
  let incomplete = false;
  for (const entry of [...created].reverse()) {
    try {
      await unchangedDirectories(parentChain, io);
      await directoryChain(dirname(entry.path), io);
      // Never traverse a substituted directory, even if a child has the old inode.
      for (const ancestor of created.filter(item => item.directory && entry.path.startsWith(`${item.path}/`))) {
        if (!ancestor.info || !sameDirectory(ancestor.info, await io.lstat(ancestor.path))) fail("concurrent_change");
      }
      const current = await io.lstat(entry.path);
      if (!entry.info || !identity(entry.info, current) || current.isSymbolicLink()
        || (entry.directory ? !current.isDirectory() : !current.isFile())) fail("concurrent_change");
      if (entry.directory) await io.rmdir(entry.path);
      else await io.unlink(entry.path);
    } catch (error) {
      if (error.code !== "ENOENT") incomplete = true;
    }
  }
  return incomplete;
}

// Explicit paths only; the destination parent must exist and the destination must not.
export async function packPlugin({ source, destination,
  marketplaceName = `quotatempo-code-${randomUUID()}` } = {}, io = fs) {
  const sourceDirectory = absolute(source);
  destination = absolute(destination);
  if (!validMarketplaceName(marketplaceName)) fail("invalid_marketplace_name");
  const parentChain = await directoryChain(dirname(destination), io);
  await missing(destination, io);
  const sourceChain = await directoryChain(sourceDirectory, io);
  const files = {};
  const records = [];
  for (const path of PLUGIN_FILES) {
    const record = await readRegular(join(sourceDirectory, path), MAX_FILE_BYTES, io);
    records.push(record);
    files[path] = record.bytes;
  }
  const releaseVersion = metadataVersion(files);
  const marketplace = json(files[PLUGIN_FILES[1]], "invalid_marketplace_metadata");
  files[PLUGIN_FILES[1]] = Buffer.from(`${JSON.stringify({ ...marketplace, name: marketplaceName }, null, 2)}\n`);
  if (files[PLUGIN_FILES[1]].length > MAX_FILE_BYTES) fail("oversize_file_rejected");
  const manifest = manifestFor(files, releaseVersion);
  await unchangedFiles(records, io);
  await unchangedDirectories(sourceChain, io);
  await unchangedDirectories(parentChain, io);
  const created = [];
  async function createDirectory(path) {
    await unchangedDirectories(parentChain, io);
    for (const entry of created.filter(item => item.directory)) {
      if (!sameDirectory(entry.info, await io.lstat(entry.path))) fail("concurrent_change");
    }
    await io.mkdir(path, { mode: 0o700 });
    const entry = { path, info: null, directory: true };
    created.push(entry);
    const info = await io.lstat(path);
    entry.info = info;
    privateEntry(info, 0o700);
  }
  async function createFile(path, bytes) {
    await unchangedDirectories(parentChain, io);
    for (const entry of created.filter(item => item.directory)) {
      if (!sameDirectory(entry.info, await io.lstat(entry.path))) fail("concurrent_change");
    }
    const handle = await io.open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    const entry = { path, info: null, directory: false };
    created.push(entry);
    try {
      const info = await handle.stat();
      entry.info = info;
      privateEntry(info, 0o600);
      await handle.writeFile(bytes);
      await handle.sync();
    } finally { await handle.close(); }
  }
  try {
    await createDirectory(destination);
    for (const directory of DIRECTORIES) await createDirectory(join(destination, directory));
    for (const path of PLUGIN_FILES) await createFile(join(destination, path), files[path]);
    await createFile(join(destination, PACKAGE_MANIFEST), Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`));
    return await verifyPackage(destination, io);
  } catch (error) {
    const cleanupIncomplete = await cleanupCreated(created, parentChain, io);
    const code = error instanceof PackageError ? error.code
      : error.code === "EEXIST" ? "destination_exists" : "package_io_failed";
    throw new PackageError(code, { cleanupIncomplete });
  }
}

export async function runCLI(args, io = fs) {
  try {
    const [command, ...flags] = args;
    const allowed = command === "pack" ? ["--source", "--destination", "--marketplace-name"]
      : command === "verify" ? ["--directory"] : [];
    if (allowed.length === 0) fail("invalid_argument");
    const options = {};
    for (let index = 0; index < flags.length; index += 2) {
      const flag = flags[index];
      if (!allowed.includes(flag) || Object.hasOwn(options, flag)) fail("invalid_argument");
      const value = flags[index + 1];
      if (!value || value.startsWith("--")) fail("missing_argument");
      options[flag] = value;
    }
    const required = command === "pack" ? ["--source", "--destination"] : ["--directory"];
    if (required.some(flag => !Object.hasOwn(options, flag))) fail("missing_argument");
    const result = command === "pack" ? await packPlugin({ source: options["--source"],
      destination: options["--destination"], marketplaceName: options["--marketplace-name"] }, io)
      : await verifyPackage(options["--directory"], io);
    const { destination, version, pluginID, packageDigest } = result;
    return { destination, version, pluginID, packageDigest };
  } catch (error) {
    return { error: error instanceof PackageError ? error.code : "package_io_failed",
      cleanupIncomplete: error instanceof PackageError && error.cleanupIncomplete };
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const result = await runCLI(process.argv.slice(2));
  if (Object.hasOwn(result, "error")) {
    console.error(JSON.stringify(result));
    process.exitCode = 1;
  } else console.log(JSON.stringify(result));
}
