#!/usr/bin/env node
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, realpath, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { parseUsage } = require('../BrowserExtension/protocol.js');
const binary = resolve(process.argv[2] ?? '.build/debug/QuotaTempoBrowserHost');
const origin = `chrome-extension://${'a'.repeat(32)}/`;
const profileID = randomUUID();
const connectionID = randomUUID();

function frame(value) {
  const body = Buffer.from(JSON.stringify(value));
  const size = Buffer.alloc(4);
  size.writeUInt32LE(body.length);
  return Buffer.concat([size, body]);
}

async function fixture(action) {
  const path = await realpath(await mkdtemp(join(tmpdir(), 'quotatempo-browser-host-test-')));
  try {
    await writeFile(join(path, 'host-config.json'), JSON.stringify({ extensionOrigin: origin }), { mode: 0o600 });
    await action(path);
  } finally { await rm(path, { recursive: true, force: true }); }
}

function run(path, bytes, caller = origin) {
  return new Promise((resolveResult, reject) => {
    const child = spawn(binary, ['--test-directory', path, caller], { stdio: ['pipe', 'pipe', 'pipe'] });
    const stdout = [], stderr = [];
    const timeout = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('host_timeout')); }, 5000);
    child.on('error', error => { clearTimeout(timeout); reject(error); });
    child.stdout.on('data', chunk => stdout.push(chunk));
    child.stderr.on('data', chunk => stderr.push(chunk));
    child.stdin.on('error', () => {});
    child.on('close', code => {
      clearTimeout(timeout);
      const output = Buffer.concat(stdout);
      try {
        assert.equal(Buffer.concat(stderr).length, 0);
        assert.ok(output.length > 4);
        assert.equal(output.readUInt32LE(0), output.length - 4);
        resolveResult({ code, ack: JSON.parse(output.subarray(4).toString()) });
      } catch (error) { reject(error); }
    });
    // Real pipes may split a native-message header or UTF-8 body anywhere.
    child.stdin.write(bytes.subarray(0, 2));
    child.stdin.end(bytes.subarray(2));
  });
}

function success(now = Date.now()) {
  return {
    schemaVersion: 1, profileID, connectionID, sequence: 1,
    observedAt: new Date(now).toISOString(), status: 'ok',
    accountFingerprint: 'a'.repeat(64), organizationFingerprint: 'b'.repeat(64),
    principalFingerprint: 'c'.repeat(64),
    ...parseUsage({ seven_day: { utilization: 27, resets_at: new Date(now + 86400000).toISOString() } }, now),
  };
}

async function connect(path) {
  const message = { ...success(), sequence: 0, status: 'connected',
    accountFingerprint: null, organizationFingerprint: null, principalFingerprint: null,
    weekly: null, fiveHour: null };
  assert.equal((await run(path, frame(message))).ack.ok, true);
}

await test('extension parser to framed native process to atomic record', () => fixture(async path => {
  await connect(path);
  const message = success();
  const result = await run(path, frame(message));
  assert.deepEqual(result, { code: 0, ack: { ok: true } });
  const record = JSON.parse(await readFile(join(path, 'browser-observation.json')));
  assert.equal(record.snapshot.source, 'claudeBrowser');
  assert.equal(record.snapshot.weekly.remainingPercent, 73);
  assert.equal(record.enabled, true);
  const failure = { ...message, sequence: 2, observedAt: new Date(Date.now()).toISOString(), status: 'signedOut', weekly: null, fiveHour: null };
  assert.equal((await run(path, frame(failure))).ack.ok, true);
  const cleared = JSON.parse(await readFile(join(path, 'browser-observation.json')));
  assert.equal(cleared.snapshot.weekly ?? null, null);
}));

await test('wrong extension origin cannot create a record', () => fixture(async path => {
  assert.equal((await run(path, frame(success()), `chrome-extension://${'b'.repeat(32)}/`)).ack.error, 'invalidMessage');
  await assert.rejects(readFile(join(path, 'browser-observation.json')), { code: 'ENOENT' });
}));

await test('mixed provider schema and microsecond offsets reach the native store as exact resets', () => fixture(async path => {
  await connect(path);
  const now = Date.now();
  const reset = new Date(now + 86400000).toISOString();
  const providerReset = reset.replace('Z', '123+00:00');
  const windows = parseUsage({
    seven_day: { utilization: 27, resets_at: providerReset },
    five_hour: null,
    limits: [{ kind: 'weekly_all', percent: 27, resets_at: providerReset,
      scope: null, is_active: false }]
  }, now);
  const message = { ...success(now), ...windows };
  assert.equal(message.weekly.resetAt, reset);
  assert.equal((await run(path, frame(message))).ack.ok, true);
  const record = JSON.parse(await readFile(join(path, 'browser-observation.json')));
  assert.equal(record.snapshot.weekly.remainingPercent, 73);
  assert.ok(Math.abs((record.snapshot.weekly.resetAt + 978307200) * 1000 - Date.parse(reset)) < 1);
  assert.notEqual(record.snapshot.weekly.resetAtIsEstimated, true);
}));

await test('oversized and truncated native messages are rejected', () => fixture(async path => {
  const size = Buffer.alloc(4); size.writeUInt32LE(20000);
  assert.equal((await run(path, size)).ack.error, 'inputTooLarge');
  assert.equal((await run(path, Buffer.from([1, 0]))).ack.error, 'truncatedMessage');
}));

await test('elapsed optional session keeps the exact weekly value through the native host', () => fixture(async path => {
  await connect(path);
  const now = Date.now();
  const weeklyReset = new Date(now + 86400000).toISOString();
  const message = { ...success(now), ...parseUsage({
    seven_day: { utilization: 27, resets_at: weeklyReset },
    five_hour: { utilization: 80, resets_at: new Date(now - 23000).toISOString() }
  }, now) };
  assert.equal(message.fiveHour, null);
  assert.equal((await run(path, frame(message))).ack.ok, true);
  const record = JSON.parse(await readFile(join(path, 'browser-observation.json')));
  assert.equal(record.lastStatus, 'ok');
  assert.equal(record.snapshot.sourceState, 'observationSucceeded');
  assert.equal(record.snapshot.weekly.remainingPercent, 73);
  assert.ok(Math.abs((record.snapshot.weekly.resetAt + 978307200) * 1000 - Date.parse(weeklyReset)) < 1);
  assert.notEqual(record.snapshot.weekly.resetAtIsEstimated, true);
  assert.equal(record.snapshot.fiveHour ?? null, null);
}));

await test('owner change clears values without rebinding', () => fixture(async path => {
  await connect(path);
  const first = success();
  assert.equal((await run(path, frame(first))).ack.ok, true);
  const changed = { ...first, sequence: 2, observedAt: new Date(Date.now()).toISOString(), accountFingerprint: 'd'.repeat(64) };
  assert.equal((await run(path, frame(changed))).ack.error, 'accountMismatch');
  const revoked = JSON.parse(await readFile(join(path, 'browser-observation.json')));
  assert.equal(revoked.snapshot.weekly ?? null, null);
  assert.equal(revoked.accountFingerprint, first.accountFingerprint);
}));

await test('slow frame sender cannot block a sign-out invalidation', () => fixture(async path => {
  await connect(path);
  assert.equal((await run(path, frame(success()))).ack.ok, true);
  const slow = spawn(binary, ['--test-directory', path, origin], { stdio: ['pipe', 'pipe', 'pipe'] });
  const closed = new Promise(resolveResult => slow.once('close', resolveResult));
  try {
    slow.stdin.write(Buffer.from([200, 0]));
    const message = { ...success(), sequence: 2, status: 'signedOut', weekly: null, fiveHour: null };
    assert.equal((await run(path, frame(message))).ack.ok, true);
    const revoked = JSON.parse(await readFile(join(path, 'browser-observation.json')));
    assert.equal(revoked.snapshot.weekly ?? null, null);
  } finally { slow.kill('SIGTERM'); await closed; }
}));
