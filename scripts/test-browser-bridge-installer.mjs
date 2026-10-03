#!/usr/bin/env node
import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { runInstaller } from './install-browser-bridge.mjs';

const execute = promisify(execFile);
const installer = fileURLToPath(new URL('./install-browser-bridge.mjs', import.meta.url));
const extensionID = 'a'.repeat(32);
const otherID = 'b'.repeat(32);
const origin = `chrome-extension://${extensionID}/`;
const hostName = 'co.ishikawa.quotatempo';
const privateError = 'SYNTHETIC_PRIVATE_ERROR /not-a-real-user/path';
const encode = value => JSON.stringify(value, null, 2) + '\n';
const ioError = () => Object.assign(new Error(privateError), { code: 'EIO' });

async function write(path, bytes, mode = 0o600) {
  await fs.mkdir(dirname(path), { recursive: true, mode: 0o700 });
  await fs.writeFile(path, bytes, { mode });
}

async function fixture(t) {
  // macOS tmpdir() may use /var, a symlink. The installer rejects symlink ancestors.
  const root = await fs.realpath(await fs.mkdtemp(join(tmpdir(), 'quotatempo-bridge-test-')));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const app = join(root, 'Fixture.app');
  const executable = join(app, 'Contents/MacOS/QuotaTempoBrowserHost');
  const support = join(root, 'support/BrowserBridge');
  const chrome = join(root, 'chrome/NativeMessagingHosts');
  const manifest = join(chrome, `${hostName}.json`);
  const config = join(support, 'host-config.json');
  const record = join(support, 'browser-observation.json');
  // This executable fixture is never run; neither the real host nor user data is used.
  await write(executable, '#!/bin/sh\nexit 1\n', 0o755);
  const directories = ['--support-dir', support, '--chrome-dir', chrome];
  const args = ['--extension-id', extensionID, '--app', app, ...directories];
  const f = { root, app, executable, support, chrome, manifest, config, record, directories, args };
  f.install = (extra = [], io) => runInstaller([...args, ...extra], io);
  f.remove = (extra = [], io) => runInstaller(['--remove', ...directories, ...extra], io);
  f.seed = async () => assert.equal((await f.install(['--apply'])).ok, true);
  f.cli = async args => {
    // Even tests of the normal, non-override CLI use a synthetic HOME.
    const env = { ...process.env, HOME: root, NODE_OPTIONS: '' };
    const cwd = root;
    try {
      const result = await execute(process.execPath, [installer, ...args], { env, cwd });
      return { ...result, status: 0 };
    } catch (error) {
      if (typeof error.code !== 'number') throw error;
      return { stdout: error.stdout, stderr: error.stderr, status: error.code };
    }
  };
  return f;
}

async function exists(path) {
  try { await fs.lstat(path); return true; } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}

async function tree(root) {
  const entries = [];
  async function visit(path, relative) {
    const info = await fs.lstat(path);
    if (info.isSymbolicLink()) entries.push([relative, 'symlink', await fs.readlink(path)]);
    else if (info.isDirectory()) {
      entries.push([relative, 'directory', info.mode & 0o777]);
      for (const name of (await fs.readdir(path)).sort()) await visit(join(path, name), join(relative, name));
    } else entries.push([relative, 'file', info.ino, info.mode & 0o777, await fs.readFile(path)]);
  }
  await visit(root, '.');
  return entries;
}

function failure(result, code = 'operation_failed', partial = false) {
  assert.deepEqual(result, { ok: false, error: code, partial });
  assert.equal(JSON.stringify(result).includes(privateError), false);
}

function failOnce(method, predicate) {
  let called = false;
  return {
    ...fs,
    [method]: async (...args) => {
      if (!called && predicate(...args)) { called = true; throw ioError(); }
      return fs[method](...args);
    },
    assertTriggered() { assert.equal(called, true, `fault at ${method} was exercised`); },
  };
}

test('help documents dry-run, corrupt-record recovery, fixture overrides and host default home', async () => {
  const io = new Proxy({}, { get() { assert.fail('help must not inspect the filesystem'); } });
  const result = await runInstaller(['--help'], io);
  assert.match(result.help, /Dry run is the default/);
  assert.match(result.help, /corrupt JSON/);
  assert.match(result.help, /Testing only: --support-dir/);
  assert.match(result.help, /native host ALWAYS uses/);
  assert.match(result.help, /not a crash-atomic/);
});

test('invalid arguments fail before filesystem access and do not echo input', async t => {
  const cases = [
    [[], 'extension_id_required'],
    [['--extension-id', 'INVALID'], 'extension_id_required'],
    [['--extension-id'], 'missing_argument'],
    [['--extension-id', '--apply'], 'missing_argument'],
    [['--remove', '--remove'], 'invalid_argument'],
    [['--remove', '--unknown-private-value'], 'invalid_argument'],
    [['--remove', '--support-dir', '/fixture'], 'fixture_overrides_required_together'],
    [['--remove', '--chrome-dir', '/fixture'], 'fixture_overrides_required_together'],
    [['--remove', '--support-dir', 'relative', '--chrome-dir', '/fixture'], 'absolute_path_required'],
    [['--remove', '--support-dir', '/fixture/../other', '--chrome-dir', '/fixture'], 'invalid_path'],
    [['--remove', '--support-dir', '/fixture\nvalue', '--chrome-dir', '/fixture'], 'invalid_path'],
  ];
  for (const [index, [args, code]] of cases.entries()) await t.test(`case ${index + 1}: ${code}`, async () => {
    const io = new Proxy({}, { get() { assert.fail('argument rejection must precede filesystem access'); } });
    failure(await runInstaller(args, io), code);
  });
});

test('default fixture install dry-run validates but creates no files or directories', async t => {
  const f = await fixture(t);
  const before = await tree(f.root);
  const result = await f.install();
  assert.equal(result.ok, true);
  assert.equal(result.applied, false);
  assert.equal(result.fixturePaths, true);
  assert.equal(result.operation, 'install');
  assert.deepEqual(await tree(f.root), before);
  assert.equal(await exists(f.support), false);
  assert.equal(await exists(f.chrome), false);
});

test('fixture apply installs exact manifests with private modes and is repeatable', async t => {
  const f = await fixture(t);
  await f.seed();
  assert.deepEqual(JSON.parse(await fs.readFile(f.manifest, 'utf8')), {
    name: hostName, description: 'QuotaTempo opt-in Claude browser bridge', path: f.executable,
    type: 'stdio', allowed_origins: [origin],
  });
  assert.deepEqual(JSON.parse(await fs.readFile(f.config, 'utf8')), { extensionOrigin: origin });
  for (const path of [f.manifest, f.config]) assert.equal((await fs.stat(path)).mode & 0o777, 0o600);
  for (const path of [f.support, f.chrome]) assert.equal((await fs.stat(path)).mode & 0o777, 0o700);
  const unrelated = join(f.support, 'claude.json');
  await write(unrelated, 'synthetic provider fixture');
  await write(f.record, 'synthetic observation kept during install');
  const config = await fs.readFile(f.config);
  await f.seed();
  assert.deepEqual(await fs.readFile(f.config), config);
  assert.equal(await fs.readFile(unrelated, 'utf8'), 'synthetic provider fixture');
  assert.equal(await fs.readFile(f.record, 'utf8'), 'synthetic observation kept during install');
  assert.equal((await tree(f.root)).some(([name]) => name.endsWith('.tmp')), false);
});

test('normal CLI paths: dry-run and apply both use synthetic HOME, never real user data', async t => {
  const f = await fixture(t);
  const args = ['--extension-id', extensionID, '--app', f.app];
  const before = await tree(f.root);
  const dry = await f.cli(args);
  assert.equal(dry.status, 0);
  assert.equal(dry.stderr, '');
  const planned = JSON.parse(dry.stdout);
  assert.equal(planned.fixturePaths, false);
  assert.equal(planned.applied, false);
  assert.equal(planned.configurationPath, join(f.root, 'Library/Application Support/QuotaTempo/BrowserBridge/host-config.json'));
  assert.equal(planned.manifestPath, join(f.root, `Library/Application Support/Google/Chrome/NativeMessagingHosts/${hostName}.json`));
  assert.deepEqual(await tree(f.root), before);
  const applied = await f.cli([...args, '--apply']);
  assert.equal(applied.status, 0);
  assert.equal(JSON.parse(applied.stdout).applied, true);
  assert.equal(await exists(planned.configurationPath), true);
  assert.equal(await exists(planned.manifestPath), true);
  const removed = await f.cli(['--remove', '--apply']);
  assert.equal(removed.status, 0);
  assert.equal(await exists(planned.configurationPath), false);
  assert.equal(await exists(planned.manifestPath), false);
});

test('CLI errors have nonzero status, no stdout and only stable public codes', async t => {
  const f = await fixture(t);
  await write(f.config, '{"private-synthetic-value":true}');
  const result = await f.cli([...f.args, '--apply']);
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  failure(JSON.parse(result.stderr), 'unrecognized_existing_file');
  assert.equal(result.stderr.includes(f.root), false);
  assert.equal(result.stderr.includes('private-synthetic-value'), false);
});

test('unrecognized manifest or config is refused before any install/remove mutation', async t => {
  const cases = [
    ['manifest', 'name alone', () => encode({ name: hostName })],
    ['manifest', 'other host', value => encode({ ...value, name: 'other.app' })],
    ['manifest', 'wrong description', value => encode({ ...value, description: 'other app' })],
    ['manifest', 'wrong type', value => encode({ ...value, type: 'other' })],
    ['manifest', 'other executable', value => encode({ ...value, path: '/fixture/other' })],
    ['manifest', 'relative executable', value => encode({ ...value, path: 'Fixture.app/Contents/MacOS/QuotaTempoBrowserHost' })],
    ['manifest', 'multiple origins', value => encode({ ...value, allowed_origins: [origin, `chrome-extension://${otherID}/`] })],
    ['manifest', 'wildcard origin', value => encode({ ...value, allowed_origins: ['chrome-extension://*/'] })],
    ['manifest', 'extra field', value => encode({ ...value, unknown: true })],
    ['manifest', 'oversized', () => ' '.repeat(16_385)],
    ['config', 'other origin', () => encode({ extensionOrigin: 'https://example.invalid/' })],
    ['config', 'wrong origin type', () => encode({ extensionOrigin: [origin] })],
    ['config', 'extra field', () => encode({ extensionOrigin: origin, unknown: true })],
    ['config', 'array', () => '[]'],
    ['config', 'invalid JSON', () => '{broken'],
    ['config', 'invalid UTF-8', () => Buffer.from([0xff])],
    ['config', 'oversized', () => ' '.repeat(1_025)],
  ];
  for (const [key, label, make] of cases) await t.test(`${key}: ${label}`, async t => {
    const f = await fixture(t);
    await f.seed();
    await write(f.record, '{corrupt recovery fixture');
    const value = JSON.parse(await fs.readFile(f[key], 'utf8'));
    await fs.writeFile(f[key], make(value));
    const before = await tree(f.root);
    for (const extra of [[], ['--apply']]) {
      failure(await f.install(extra), 'unrecognized_existing_file');
      failure(await f.remove(extra), 'unrecognized_existing_file');
      assert.deepEqual(await tree(f.root), before);
    }
  });
});

test('origin mismatches refuse all writes and optional removal ID guards the owner', async t => {
  const f = await fixture(t);
  await f.seed();
  let before = await tree(f.root);
  failure(await f.remove(['--extension-id', otherID, '--apply']), 'origin_mismatch');
  assert.deepEqual(await tree(f.root), before);
  await fs.writeFile(f.config, encode({ extensionOrigin: `chrome-extension://${otherID}/` }));
  before = await tree(f.root);
  failure(await f.install(['--apply']), 'origin_mismatch');
  failure(await f.remove(['--apply']), 'origin_mismatch');
  assert.deepEqual(await tree(f.root), before);
});

test('executable must exist, be executable and live in a recognized app path', async t => {
  const f = await fixture(t);
  await fs.chmod(f.executable, 0o600);
  failure(await f.install(['--apply']));
  assert.equal(await exists(f.config), false);
  await fs.unlink(f.executable);
  failure(await f.install());
  const other = join(f.root, 'NotAnApp');
  const args = ['--extension-id', extensionID, '--app', other, ...f.directories];
  failure(await runInstaller(args), 'invalid_app_path');
  assert.equal(await exists(f.support), false);
});

test('symlink leaves including dangling links are refused without following targets', async t => {
  for (const key of ['manifest', 'config', 'record', 'executable']) {
    for (const dangling of [false, true]) await t.test(`${key}, dangling=${dangling}`, async t => {
      const f = await fixture(t);
      await f.seed();
      const target = join(f.root, 'unrelated-target');
      if (!dangling) await write(target, 'unrelated synthetic data');
      if (await exists(f[key])) await fs.unlink(f[key]);
      await fs.symlink(target, f[key]);
      const before = await tree(f.root);
      if (key !== 'record') failure(await f.install(['--apply']), 'symlink_rejected');
      if (key !== 'executable') failure(await f.remove(['--apply']), 'symlink_rejected');
      assert.deepEqual(await tree(f.root), before);
    });
  }
});

test('symlink ancestors are refused for support, Chrome and app paths', async t => {
  for (const key of ['support', 'chrome', 'app']) await t.test(key, async t => {
    const f = await fixture(t);
    const target = join(f.root, `${key}-target`);
    await fs.mkdir(dirname(f[key]), { recursive: true });
    if (await exists(f[key])) await fs.rename(f[key], target);
    else await fs.mkdir(target);
    await fs.symlink(target, f[key]);
    const before = await tree(f.root);
    failure(await f.install(['--apply']), 'symlink_rejected');
    if (key !== 'app') failure(await f.remove(['--apply']), 'symlink_rejected');
    assert.deepEqual(await tree(f.root), before);
  });
});

test('nonregular targets and hard links are refused before any removal', async t => {
  for (const key of ['manifest', 'config', 'record']) {
    for (const kind of ['directory', 'hardlink']) await t.test(`${key}: ${kind}`, async t => {
      const f = await fixture(t);
      await f.seed();
      if (!(await exists(f[key]))) await write(f[key], 'corrupt observation fixture');
      if (kind === 'directory') { await fs.unlink(f[key]); await fs.mkdir(f[key]); }
      else await fs.link(f[key], join(f.root, 'other-provider-record'));
      const before = await tree(f.root);
      failure(await f.remove(['--apply']), 'unsafe_existing_file');
      if (key !== 'record') failure(await f.install(['--apply']), 'unsafe_existing_file');
      assert.deepEqual(await tree(f.root), before);
    });
  }
});

test('removal dry-run preserves every file; apply removes only the exact three bridge files', async t => {
  const f = await fixture(t);
  await f.seed();
  await write(f.record, '{corrupt synthetic observation');
  const preserved = [
    join(f.support, 'claude.json'), join(f.support, 'codex.json'), join(f.support, 'host.lock'),
    join(f.support, 'nested/browser-observation.json'), join(dirname(f.support), 'claude.json'),
    join(f.chrome, 'other.native.host.json'),
  ];
  for (const [index, path] of preserved.entries()) await write(path, `synthetic unrelated file ${index}`);
  await fs.rm(f.app, { recursive: true });
  const before = await tree(f.root);
  const dry = await f.remove();
  assert.equal(dry.ok, true);
  assert.equal(dry.applied, false);
  assert.equal(dry.operation, 'remove');
  assert.deepEqual(await tree(f.root), before);
  const applied = await f.remove(['--extension-id', extensionID, '--apply']);
  assert.equal(applied.ok, true);
  assert.equal(applied.applied, true);
  for (const path of [f.manifest, f.config, f.record]) assert.equal(await exists(path), false);
  for (const [index, path] of preserved.entries()) assert.equal(await fs.readFile(path, 'utf8'), `synthetic unrelated file ${index}`);
  assert.equal(await exists(f.support), true);
  assert.equal(await exists(f.chrome), true);
  assert.equal((await tree(f.root)).some(([name]) => name.endsWith('.tmp')), false);
  const removed = await tree(f.root);
  assert.equal((await f.remove(['--apply'])).ok, true);
  assert.deepEqual(await tree(f.root), removed);
});

test('corrupt or future-schema observation recovery reads metadata only, even without config/manifest', async t => {
  const cases = [
    ['empty', Buffer.alloc(0)], ['invalid JSON', Buffer.from('{broken')],
    ['invalid UTF-8', Buffer.from([0xff, 0xfe, 0x00])], ['oversized', Buffer.alloc(70_000, 0xff)],
    ['future schema', Buffer.from('{"schemaVersion":999,"generation":7,"sequence":42}')],
  ];
  for (const [label, bytes] of cases) await t.test(label, async t => {
    const f = await fixture(t);
    await write(f.record, bytes);
    const opened = [];
    const io = { ...fs, open: async (...args) => { opened.push(args[0]); return fs.open(...args); } };
    assert.equal((await f.remove([], io)).ok, true);
    assert.deepEqual(await fs.readFile(f.record), bytes);
    assert.equal((await f.remove(['--apply'], io)).ok, true);
    assert.deepEqual(opened, [], 'observation body must never be read');
    assert.equal(await exists(f.record), false, 'no stale observation selection file remains');
    assert.equal(await exists(f.chrome), false);
    assert.deepEqual(await fs.readdir(f.support), []);
  });
});

test('empty removal does not require app or extension ID and creates nothing', async t => {
  const f = await fixture(t);
  await fs.rm(f.app, { recursive: true });
  const before = await tree(f.root);
  for (const extra of [[], ['--apply']]) assert.equal((await f.remove(extra)).ok, true);
  assert.deepEqual(await tree(f.root), before);
});

test('staging failures leave original files byte-for-byte and clean temporary files', async t => {
  for (const stage of ['open', 'write', 'sync']) await t.test(stage, async t => {
    const f = await fixture(t);
    await f.seed();
    const before = await tree(f.root);
    let triggered = false;
    const io = {
      ...fs,
      open: async (path, flags, mode) => {
        if (flags !== 'wx' || dirname(path) !== f.chrome) return fs.open(path, flags, mode);
        triggered = true;
        if (stage === 'open') throw ioError();
        const handle = await fs.open(path, flags, mode);
        return {
          writeFile: async bytes => {
            if (stage === 'write') { await handle.writeFile(bytes.subarray(0, 3)); throw ioError(); }
            return handle.writeFile(bytes);
          },
          sync: async () => { if (stage === 'sync') throw ioError(); return handle.sync(); },
          close: () => handle.close(),
        };
      },
    };
    failure(await f.install(['--apply'], io));
    assert.equal(triggered, true);
    assert.deepEqual(await tree(f.root), before);
  });
});

test('installation publish failure rolls back existing originals, including modes and inode', async t => {
  const f = await fixture(t);
  await f.seed();
  await fs.chmod(f.config, 0o640);
  await fs.writeFile(f.config, encode({ extensionOrigin: `chrome-extension://${otherID}/` }));
  const manifest = JSON.parse(await fs.readFile(f.manifest, 'utf8'));
  await fs.writeFile(f.manifest, encode({ ...manifest, allowed_origins: [`chrome-extension://${otherID}/`] }));
  const before = await tree(f.root);
  const io = failOnce('link', (source, target) => target === f.manifest);
  failure(await f.install(['--apply'], io));
  io.assertTriggered();
  assert.deepEqual(await tree(f.root), before);
});

test('new install failure removes the newly published config and all staged files', async t => {
  const f = await fixture(t);
  await fs.mkdir(f.support, { recursive: true, mode: 0o700 });
  await fs.mkdir(f.chrome, { recursive: true, mode: 0o700 });
  const before = await tree(f.root);
  const io = failOnce('link', (source, target) => target === f.manifest);
  failure(await f.install(['--apply'], io));
  io.assertTriggered();
  assert.deepEqual(await tree(f.root), before);
});

test('failed unlink after publication rolls back despite the temporary second hard link', async t => {
  const f = await fixture(t);
  await f.seed();
  const before = await tree(f.root);
  const io = failOnce('unlink', path => basename(path).startsWith('.host-config.json.'));
  failure(await f.install(['--apply'], io));
  io.assertTriggered();
  assert.deepEqual(await tree(f.root), before);
});

test('removal failure rolls back all detached originals and never opens observation contents', async t => {
  for (const key of ['config', 'record']) await t.test(`failure detaching ${key}`, async t => {
    const f = await fixture(t);
    await f.seed();
    await write(f.record, Buffer.from([0xff, 0x00]));
    const before = await tree(f.root);
    const fault = failOnce('rename', path => path === f[key]);
    const opened = [];
    const io = { ...fault, open: async (...args) => { opened.push(args[0]); return fs.open(...args); } };
    failure(await f.remove(['--apply'], io));
    fault.assertTriggered();
    assert.equal(opened.some(path => basename(path).includes('browser-observation.json')), false);
    assert.deepEqual(await tree(f.root), before);
  });
});

test('precommit revalidation detects a changed target without replacing it', async t => {
  const f = await fixture(t);
  await f.seed();
  const config = await fs.readFile(f.config);
  let triggered = false;
  const io = {
    ...fs,
    open: async (...args) => {
      if (args[1] === 'wx' && dirname(args[0]) === f.chrome) {
        triggered = true;
        await fs.writeFile(f.manifest, 'concurrently changed synthetic fixture');
      }
      return fs.open(...args);
    },
  };
  failure(await f.install(['--apply'], io), 'concurrent_change');
  assert.equal(triggered, true);
  assert.deepEqual(await fs.readFile(f.config), config);
  assert.equal(await fs.readFile(f.manifest, 'utf8'), 'concurrently changed synthetic fixture');
  assert.equal((await tree(f.root)).some(([name]) => name.endsWith('.tmp')), false);
});

test('exclusive publication never overwrites a newly created unrelated target', async t => {
  const f = await fixture(t);
  let triggered = false;
  const io = {
    ...fs,
    link: async (source, target) => {
      if (target === f.manifest) {
        triggered = true;
        await fs.writeFile(target, 'concurrent unrelated manifest');
      }
      return fs.link(source, target);
    },
  };
  failure(await f.install(['--apply'], io));
  assert.equal(triggered, true);
  assert.equal(await fs.readFile(f.manifest, 'utf8'), 'concurrent unrelated manifest');
  assert.equal(await exists(f.config), false);
  assert.equal((await tree(f.root)).some(([name]) => name.endsWith('.tmp')), false);
});

test('rollback failure is reported as partial and preserves concurrent data and recovery backup', async t => {
  const f = await fixture(t);
  await f.seed();
  const originalConfig = await fs.readFile(f.config);
  let triggered = false;
  const io = {
    ...fs,
    link: async (source, target) => {
      if (!triggered && target === f.manifest) {
        triggered = true;
        await fs.writeFile(f.config, 'concurrent config mutation');
        throw ioError();
      }
      return fs.link(source, target);
    },
  };
  failure(await f.install(['--apply'], io), 'rollback_incomplete', true);
  assert.equal(triggered, true);
  assert.equal(await fs.readFile(f.config, 'utf8'), 'concurrent config mutation');
  assert.equal(await exists(f.manifest), true);
  const backup = (await fs.readdir(f.support)).find(name => name.startsWith('.host-config.json.'));
  assert.ok(backup);
  assert.deepEqual(await fs.readFile(join(f.support, backup)), originalConfig);
});

test('removal does not report success when an observation is recreated before commit completes', async t => {
  const f = await fixture(t);
  await f.seed();
  const original = Buffer.from([0xff, 0x00]);
  await write(f.record, original);
  let backup;
  const io = {
    ...fs,
    rename: async (source, target) => {
      await fs.rename(source, target);
      if (source === f.record) {
        backup = target;
        await fs.writeFile(f.record, 'concurrent observation fixture');
      }
    },
  };
  failure(await f.remove(['--apply'], io), 'rollback_incomplete', true);
  assert.equal(await exists(f.manifest), true);
  assert.equal(await exists(f.config), true);
  assert.equal(await fs.readFile(f.record, 'utf8'), 'concurrent observation fixture');
  assert.deepEqual(await fs.readFile(backup), original);
});

test('backup cleanup failure reports partial applied state, not a false success', async t => {
  const f = await fixture(t);
  await f.seed();
  const backups = new Set();
  let triggered = false;
  const io = {
    ...fs,
    rename: async (source, target) => { await fs.rename(source, target); backups.add(target); },
    unlink: async path => {
      if (!triggered && backups.has(path)) { triggered = true; throw ioError(); }
      return fs.unlink(path);
    },
  };
  failure(await f.install(['--apply'], io), 'cleanup_incomplete', true);
  assert.equal(triggered, true);
  assert.equal(await exists(f.config), true);
  assert.equal(await exists(f.manifest), true);
  assert.equal((await tree(f.root)).filter(([name]) => name.endsWith('.tmp')).length, 1);
});

test('unexpected filesystem exceptions never expose their paths or data', async t => {
  const f = await fixture(t);
  failure(await f.install([], { ...fs, lstat: async () => { throw ioError(); } }));
  assert.equal(resolve(f.root), f.root);
});
