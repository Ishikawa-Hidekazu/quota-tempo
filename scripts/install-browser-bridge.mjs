#!/usr/bin/env node
import * as fs from 'node:fs/promises';
import { constants } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, isAbsolute, join, parse, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';

const hostName = 'co.ishikawa.quotatempo';
const description = 'QuotaTempo opt-in Claude browser bridge';
const originPattern = /^chrome-extension:\/\/[a-p]{32}\/$/;

const help = `Usage: node scripts/install-browser-bridge.mjs --extension-id ID [--app ABSOLUTE_APP] [--apply]
       node scripts/install-browser-bridge.mjs --remove [--extension-id ID] [--apply]

Dry run is the default, including removal. --apply is required for all changes.
Removal needs no installed app. It removes only recognized bridge manifest and
host-config.json, plus the exact browser-observation.json regular file, including
corrupt JSON, as recovery. Symlinks/hard links are refused. No other app/provider
records or directories are removed. Successful removal leaves no browser
observation file for selection on the next app refresh.
An optional removal extension ID must match any existing manifest/config.
Stop sending bridge observations before removal. Concurrent changes are refused
when detected; this installer does not lock or manipulate the running host.

Testing only: --support-dir ABSOLUTE_DIR --chrome-dir ABSOLUTE_DIR
Supply both overrides together, using real paths without symlink components.
They redirect installer fixture files only. The native host ALWAYS uses the
default home Library/Application Support/QuotaTempo/BrowserBridge directory;
these flags do not configure a custom runtime location or a working installation.

Writes are staged and recoverable errors roll back. This is not a crash-atomic
transaction across directories. cleanup_incomplete means changes applied but
staged backups remain; rollback_incomplete requires manual inspection. Errors
report stable codes, never file contents or underlying filesystem error text.
`;

class InstallerError extends Error {
  constructor(code, partial = false) {
    super(code);
    this.partial = partial;
  }
}
function fail(code) { throw new InstallerError(code); }
function object(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function keys(value, required, optional = []) {
  return object(value) && required.every(key => Object.hasOwn(value, key))
    && Object.keys(value).every(key => required.includes(key) || optional.includes(key));
}

function appPath(value) {
  return typeof value === 'string' && isAbsolute(value) && resolve(value) === value
    && !/[\x00-\x1f\x7f]/.test(value)
    && basename(value) === 'QuotaTempoBrowserHost' && basename(dirname(value)) === 'MacOS'
    && basename(dirname(dirname(value))) === 'Contents'
    && basename(dirname(dirname(dirname(value)))).endsWith('.app');
}
function recognizedManifest(value) {
  return keys(value, ['name', 'description', 'path', 'type', 'allowed_origins'])
    && value.name === hostName && value.description === description && value.type === 'stdio'
    && appPath(value.path) && Array.isArray(value.allowed_origins)
    && value.allowed_origins.length === 1 && typeof value.allowed_origins[0] === 'string'
    && originPattern.test(value.allowed_origins[0]);
}
function recognizedConfig(value) {
  return keys(value, ['extensionOrigin']) && typeof value.extensionOrigin === 'string'
    && originPattern.test(value.extensionOrigin);
}

function argumentsFor(args) {
  const result = {};
  const flags = ['--apply', '--remove', '--help'];
  const values = ['--extension-id', '--support-dir', '--chrome-dir', '--app'];
  for (let index = 0; index < args.length; index++) {
    const flag = args[index];
    if (![...flags, ...values].includes(flag) || Object.hasOwn(result, flag)) fail('invalid_argument');
    if (flags.includes(flag)) result[flag] = true;
    else {
      const value = args[++index];
      if (!value || value.startsWith('--')) fail('missing_argument');
      result[flag] = value;
    }
  }
  return result;
}
function absolute(value) {
  if (!isAbsolute(value)) fail('absolute_path_required');
  if (/[\x00-\x1f\x7f]/.test(value) || value.split('/').includes('..')) fail('invalid_path');
  return resolve(value);
}
async function safePath(path, io) {
  let current = parse(path).root;
  for (const part of path.slice(current.length).split('/').filter(Boolean)) {
    current = join(current, part);
    try {
      const info = await io.lstat(current);
      if (info.isSymbolicLink()) fail('symlink_rejected');
      if (current !== path && !info.isDirectory()) fail('unsafe_existing_file');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
}

function sameFile(left, right) {
  return left.dev === right.dev && left.ino === right.ino && left.size === right.size
    && left.mtimeMs === right.mtimeMs && left.mode === right.mode;
}
async function readExisting(path, maximumBytes, io, metadataOnly = false) {
  await safePath(path, io);
  let info;
  try { info = await io.lstat(path); } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
  if (!info.isFile() || info.nlink !== 1) fail('unsafe_existing_file');
  if (metadataOnly) return { info };
  if (info.size > maximumBytes) fail('unrecognized_existing_file');
  const handle = await io.open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const opened = await handle.stat();
    if (!sameFile(info, opened)) fail('concurrent_change');
    const bytes = Buffer.alloc(maximumBytes + 1);
    const { bytesRead } = await handle.read(bytes, 0, bytes.length, 0);
    const after = await handle.stat();
    if (!sameFile(opened, after) || bytesRead !== info.size) fail('concurrent_change');
    return { bytes: bytes.subarray(0, bytesRead), info };
  } finally { await handle.close(); }
}
async function prevalidate(entry, io) {
  entry.before = await readExisting(entry.path, entry.limit, io, entry.metadataOnly);
  if (!entry.before || entry.metadataOnly) return;
  let value;
  try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(entry.before.bytes)); }
  catch { fail('unrecognized_existing_file'); }
  if (!entry.recognize(value)) fail('unrecognized_existing_file');
  entry.value = value;
}
async function assertUnchanged(entry, expected, io) {
  const current = await readExisting(entry.path, entry.limit, io, entry.metadataOnly);
  if (Boolean(current) !== Boolean(expected)
    || (current && (!sameFile(current.info, expected.info)
      || (!entry.metadataOnly && !current.bytes.equals(expected.bytes))))) {
    fail('concurrent_change');
  }
}
function temporary(path) { return join(dirname(path), `.${basename(path)}.${randomUUID()}.tmp`); }

// Detach originals only after every target and replacement has been validated.
// Exclusive links publish/restore without overwriting a concurrently created file.
async function apply(entries, io) {
  try {
    for (const entry of entries) {
      if (!entry.after) continue;
      await safePath(entry.path, io);
      await io.mkdir(dirname(entry.path), { recursive: true, mode: 0o700 });
      await safePath(entry.path, io);
      const stage = temporary(entry.path);
      const handle = await io.open(stage, 'wx', 0o600);
      entry.stage = stage;
      try { await handle.writeFile(entry.after); await handle.sync(); } finally { await handle.close(); }
    }
    for (const entry of entries) await assertUnchanged(entry, entry.before, io);
    for (const entry of entries) {
      await assertUnchanged(entry, entry.before, io);
      if (entry.before) {
        const backup = temporary(entry.path);
        await io.rename(entry.path, backup);
        entry.backup = backup;
        const moved = await readExisting(backup, entry.limit, io, entry.metadataOnly);
        if (!moved || !sameFile(moved.info, entry.before.info)
          || (!entry.metadataOnly && !moved.bytes.equals(entry.before.bytes))) fail('concurrent_change');
      }
      if (entry.after) {
        await safePath(entry.path, io);
        entry.published = { info: await io.lstat(entry.stage), bytes: entry.after };
        await io.link(entry.stage, entry.path);
        entry.installed = true;
        await io.unlink(entry.stage);
        entry.stage = null;
        await assertUnchanged(entry, entry.published, io);
      }
    }
    for (const entry of entries) await assertUnchanged(entry, entry.after ? entry.published : null, io);
  } catch (error) {
    let failed = false;
    for (const entry of [...entries].reverse()) {
      try {
        if (entry.installed) {
          // If unlinking the stage failed, its hard link still identifies our file.
          if (!entry.stage) await assertUnchanged(entry, entry.published, io);
          else {
            await safePath(entry.path, io);
            await safePath(entry.stage, io);
            const current = await io.lstat(entry.path);
            const staged = await io.lstat(entry.stage);
            if (!current.isFile() || !sameFile(current, staged)
              || !sameFile(current, entry.published.info)) fail('concurrent_change');
          }
          await io.unlink(entry.path);
        }
        if (entry.backup) {
          await safePath(entry.path, io);
          await assertUnchanged({ ...entry, path: entry.backup }, entry.before, io);
          await io.link(entry.backup, entry.path);
          await io.unlink(entry.backup);
          entry.backup = null;
        }
      } catch { failed = true; }
    }
    for (const entry of entries) {
      if (entry.stage) try { await safePath(entry.stage, io); await io.unlink(entry.stage); entry.stage = null; } catch { failed = true; }
    }
    if (failed) throw new InstallerError('rollback_incomplete', true);
    throw error;
  }
  let failed = false;
  for (const entry of entries) {
    if (entry.backup) try {
      await assertUnchanged({ ...entry, path: entry.backup }, entry.before, io);
      await io.unlink(entry.backup);
    } catch { failed = true; }
  }
  if (failed) throw new InstallerError('cleanup_incomplete', true);
}

// The injected filesystem is for isolated fault tests; no CLI flag changes it.
export async function runInstaller(args, io = fs) {
  try {
    const options = argumentsFor(args);
    if (options['--help']) return { help };
    const remove = options['--remove'] === true;
    const extensionID = options['--extension-id'];
    if ((!remove || extensionID !== undefined) && !/^[a-p]{32}$/.test(extensionID ?? '')) fail('extension_id_required');
    const fixturePaths = Boolean(options['--support-dir'] || options['--chrome-dir']);
    if (fixturePaths && (!options['--support-dir'] || !options['--chrome-dir'])) fail('fixture_overrides_required_together');
    const support = absolute(options['--support-dir'] ?? join(homedir(), 'Library/Application Support/QuotaTempo/BrowserBridge'));
    const chrome = absolute(options['--chrome-dir'] ?? join(homedir(), 'Library/Application Support/Google/Chrome/NativeMessagingHosts'));
    const executable = join(absolute(options['--app'] ?? '/Applications/QuotaTempo.app'), 'Contents/MacOS/QuotaTempoBrowserHost');
    const origin = extensionID ? `chrome-extension://${extensionID}/` : null;
    const manifestPath = join(chrome, `${hostName}.json`);
    const configurationPath = join(support, 'host-config.json');
    const recordPath = join(support, 'browser-observation.json');
    const encode = value => Buffer.from(JSON.stringify(value, null, 2) + '\n');
    const entries = [
      { path: manifestPath, limit: 16_384, recognize: recognizedManifest,
        after: remove ? null : encode({ name: hostName, description, path: executable, type: 'stdio', allowed_origins: [origin] }) },
      { path: configurationPath, limit: 1_024, recognize: recognizedConfig,
        after: remove ? null : encode({ extensionOrigin: origin }) },
    ];
    // Recovery owns this exact filename, not its JSON schema. Never read its body.
    if (remove) entries.push({ path: recordPath, metadataOnly: true, after: null });
    else {
      if (!appPath(executable)) fail('invalid_app_path');
      await safePath(executable, io);
      if (!(await io.lstat(executable)).isFile()) fail('unsafe_existing_file');
      await io.access(executable, constants.X_OK);
    }
    for (const entry of entries) await prevalidate(entry, io);
    const origins = [entries[0].value?.allowed_origins[0], entries[1].value?.extensionOrigin].filter(Boolean);
    if (new Set(origins).size > 1 || (remove && origin && origins.some(value => value !== origin))) fail('origin_mismatch');
    if (options['--apply']) {
      // Install config before exposing the host; remove the manifest before its data.
      await apply(remove ? entries : [entries[1], entries[0]], io);
    }
    return { ok: true, applied: options['--apply'] === true, operation: remove ? 'remove' : 'install',
      fixturePaths, manifestPath, configurationPath, ...(remove ? { recordPath } : {}) };
  } catch (error) {
    return { ok: false, error: error instanceof InstallerError ? error.message : 'operation_failed',
      partial: error instanceof InstallerError && error.partial };
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const result = await runInstaller(process.argv.slice(2));
  if (result.help) console.log(result.help);
  else if (result.ok) console.log(JSON.stringify(result));
  else { console.error(JSON.stringify(result)); process.exitCode = 1; }
}
