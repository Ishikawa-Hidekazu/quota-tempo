import { constants } from "node:fs";
import { lstat, mkdir, open } from "node:fs/promises";
import { dirname, isAbsolute, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { createComparisonReceiver, decodeGrant, MAX_BYTES, UUID } from "./protocol.mjs";

async function checkPath(path) {
  if (!isAbsolute(path) || resolve(path) !== path) throw new Error("unsafe_path");
  for (let item = path; ; item = dirname(item)) {
    const stat = await lstat(item);
    if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error("unsafe_path");
    if (dirname(item) === item) break;
  }
}

async function checkDirectory(directory) {
  await checkPath(directory);
  const stat = await lstat(directory);
  if (stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o700) throw new Error("unsafe_path");
}

async function readMetadata(path, limit) {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = await file.stat();
    // The Mods write API cannot choose a file mode. Its enclosing directory
    // must be owner-only; group/other writes to the file are still rejected.
    if (!stat.isFile() || stat.uid !== process.getuid() || stat.nlink !== 1
      || (stat.mode & 0o022) !== 0 || stat.size < 1 || stat.size > limit) throw new Error("invalid_file");
    const buffer = Buffer.alloc(limit + 1);
    const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
    if (bytesRead > limit) throw new Error("invalid_file");
    return new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, bytesRead));
  } finally { await file.close(); }
}

export async function prepareDirectory(directory, now = Date.now()) {
  await checkPath(dirname(directory));
  if (!isAbsolute(directory) || resolve(directory) !== directory || !Number.isFinite(now)) throw new Error("unsafe_path");
  await mkdir(directory, { mode: 0o700 });
  await checkDirectory(directory);
  const grant = { schemaVersion: 1, purpose: "quotatempo-mods-comparison",
    connectionID: randomUUID(), createdAt: new Date(now).toISOString() };
  const file = await open(`${directory}/probe-grant.json`, "wx", 0o600);
  try { await file.writeFile(JSON.stringify(grant)); } finally { await file.close(); }
  return { status: "prepared", connectionID: grant.connectionID };
}

export async function readStreamRecord(directory, streamID) {
  if (!UUID.test(streamID)) throw new Error("invalid_stream");
  await checkDirectory(directory);
  // Grant age limits connecting, not inspecting an already connected stream.
  const text = await readMetadata(`${directory}/probe-grant.json`, 1024);
  const raw = JSON.parse(text);
  const grant = decodeGrant(text, Date.parse(raw.createdAt));
  if (!grant) throw new Error("invalid_grant");
  const message = await readMetadata(`${directory}/stream-${streamID}.json`, MAX_BYTES);
  return { connectionID: grant.connectionID, streamID, message };
}

export async function inspectStream(directory, streamID, now = Date.now()) {
  const record = await readStreamRecord(directory, streamID);
  return createComparisonReceiver(record).consume(record.message, now);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [command, directory, streamID, ...rest] = process.argv.slice(2);
    if (rest.length || !directory) throw new Error();
    const result = command === "prepare" && !streamID ? await prepareDirectory(directory)
      : command === "inspect" && streamID ? await inspectStream(directory, streamID) : null;
    if (!result) throw new Error();
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch {
    process.stdout.write('{"status":"probe_unavailable","automaticSelectionEligible":false}\n');
    process.exitCode = 1;
  }
}
