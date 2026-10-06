import { createUsageProducer } from "../producer.mjs";
import { decodeGrant, encodeMessage } from "../protocol.mjs";
import { sealRequest } from "../transport-crypto.mjs";

const COMMAND = "quotatempo-probe";
const POST_DEADLINE_MS = 5_000;
const DISCONNECT_UNCONFIRMED = "QuotaTempo probe stopped locally. Disconnect confirmation failed; prepare a new private comparison directory. No product source was changed.";
const PATH_PATTERN = /^\/(?:[^\x00-\x1f\\/]+\/)*[^\x00-\x1f\\/]+$/;

function validDirectory(path) {
  return typeof path === "string" && path.length <= 1024 && PATH_PATTERN.test(path)
    && path.split("/").every(part => part !== "." && part !== "..");
}

// A nonsecret stream label, not an account identifier or authentication token.
function streamID() {
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, char => {
    const n = Math.floor(Math.random() * 16);
    return (char === "x" ? n : (n & 3) | 8).toString(16);
  });
}

async function directoryIsSafe($, path) {
  const stat = await $.fs.stat(path, { resolve: true });
  return stat.kind === "dir" && !stat.isLink && stat.realPath === path;
}

async function writeIsSafe($, path) {
  if (!(await $.fs.exists(path))) return true;
  const stat = await $.fs.stat(path, { resolve: true });
  return stat.kind === "file" && !stat.isLink && stat.realPath === path;
}

async function verifyGrant($, current) {
  // FsStat has no UID, mode or inode. The native listener MUST check its own
  // private directory/socket mode, socket inode and connecting client peer UID.
  // Server identity comes from the command-pinned key, not this mutable file.
  // Even a replaced endpoint receives only HPKE ciphertext, never quota text.
  if (!(await directoryIsSafe($, current.directory))) throw new Error();
  const grantPath = `${current.directory}/probe-grant.json`;
  if (!(await writeIsSafe($, grantPath)) || !(await $.fs.exists(grantPath))) throw new Error();
  const grantStat = await $.fs.stat(grantPath);
  if (grantStat.size > 1024 || await $.fs.read(grantPath) !== current.grantText) throw new Error();
}

async function post($, current, endpoint, body, expected, operation) {
  // An unfinished host fetch must not retain the quota-bearing connection.
  const control = current.control ?? current;
  current = null;
  let plaintext = body;
  body = null;
  let sealed;
  let timer;
  let live = true;
  const deadline = new Promise((_, reject) => {
    try {
      timer = $.clock.after(POST_DEADLINE_MS, () => {
        live = false;
        reject(new Error());
      });
    } catch {
      live = false;
      reject(new Error());
    }
  });
  try {
    await Promise.race([deadline, (async () => {
      if (!live || operation?.abandoned) throw new Error();
      await verifyGrant($, control);
      if (!live || operation?.abandoned) throw new Error();
      const envelope = await sealRequest(control.publicKey, control.connectionID,
        control.streamID, endpoint, plaintext);
      if (!live || operation?.abandoned) { envelope.destroy(); throw new Error(); }
      sealed = envelope;
      plaintext = null;
      if (endpoint === "connect") control.connectAttempted = true;
      const response = await $.http.fetch(`http://quotatempo/${endpoint}`, {
        method: "POST", socketPath: control.socketPath,
        headers: { "Content-Type": "application/json" }, body: sealed.body,
      });
      // HttpInit has no abort/deadline option. A late host reply is ignored,
      // even when its proof is authentic; uncertain requests are never replayed.
      if (!live || operation?.abandoned) throw new Error();
      if (response.status !== 200 || response.ok !== true || typeof response.text !== "string"
        || response.text.length > 1024) throw new Error();
      sealed.verify(JSON.parse(response.text), expected);
      if (endpoint === "connect") {
        control.connectConfirmed = true;
        await verifyGrant($, control);
        if (!live || operation?.abandoned) throw new Error();
      }
    })()]);
  } finally {
    live = false;
    plaintext = null;
    sealed?.destroy();
    timer?.cancel();
  }
}

function clearUsage(current) {
  current.usage = null;
  current.readAt = null;
  current.latest = null;
}

function binding(current) {
  return JSON.stringify({ schemaVersion: 2, connectionID: current.connectionID, streamID: current.streamID });
}

async function disconnectControl($, control) {
  if (control.disconnectAttempted) return control.disconnectConfirmed;
  control.disconnectAttempted = true;
  try {
    await post($, control, "disconnect", binding(control), "disconnected");
    control.disconnectConfirmed = true;
  } catch { /* An uncertain control request is never automatically replayed. */ }
  return control.disconnectConfirmed;
}

async function writeResult($, current, result) {
  const text = encodeMessage({ connectionID: current.connectionID, streamID: current.streamID,
    sequence: ++current.sequence, result });
  if (current.schemaVersion === 3) {
    await post($, current, "measure", text, "accepted");
    return;
  }
  // Explicitly experimental schema 1 file transport.
  await verifyGrant($, current);
  if (!(await writeIsSafe($, current.path))) throw new Error();
  await $.fs.write(current.path, text);
}

async function deliver($, state, current) {
  try {
    while (state.active === current && current.latest) {
      const latest = current.latest;
      current.latest = null;
      current.readAt = latest.readAt;
      current.usage = { rateLimits: latest.rateLimits };
      const result = await current.producer.poll();
      current.usage = null;
      current.readAt = null;
      if (state.active === current) await writeResult($, current, result);
    }
  } catch {
    if (state.active === current) {
      state.active = null;
      clearUsage(current);
      current.producer = null;
      // Protected IPC stops on error: no retry, file invalidation or fallback.
      if (current.schemaVersion === 3) {
        state.deadBinding = current.control;
        return;
      }
      // One experimental file invalidation, not a quota delivery retry.
      try {
        await writeResult($, current, { schemaVersion: 1, status: "unavailable",
          reason: "export_failed", readAt: null, rateLimits: [] });
      } catch {}
    }
  } finally {
    clearUsage(current);
    state.busy = false;
  }
}

async function stop($, state) {
  state.generation++;
  const current = state.active;
  const handshake = state.handshakePromise;
  const dead = state.deadBinding;
  state.active = null;
  if (!current && !handshake && !dead) return state.closing;
  if (current) {
    clearUsage(current);
    current.producer = null;
  }
  const previous = state.closing;
  state.closing = (async () => {
    await previous;
    // Connect registers this promise only AFTER its own stop, avoiding self-wait.
    await handshake;
    const control = current ? current.control : dead ?? state.deadBinding;
    if (control) {
      await control.pending;
      state.deadBinding = control;
      const confirmed = await disconnectControl($, control);
      if (confirmed && state.deadBinding === control) state.deadBinding = null;
      return confirmed;
    }
    if (!current) return true;
    // Only the bounded delivery wrapper is drained, never a raw host fetch.
    await current.pending;
    try {
      let readAt = null;
      try { readAt = new Date(await $.clock.now()).toISOString(); } catch {}
      const result = { schemaVersion: 1, status: "unavailable", reason: "disconnected",
        readAt, rateLimits: [] };
      await writeResult($, current, result);
      return !state.deadBinding;
    } catch { return false; }
  })();
  return state.closing;
}

async function finishConnection($, state, current, generation, operation) {
  try {
    if (current.schemaVersion === 3) {
      await post($, current, "connect", binding(current), "connected", operation);
    }
    if (state.generation !== generation) {
      if (current.control && !(await disconnectControl($, current.control))) {
        state.deadBinding = current.control;
        return { text: DISCONNECT_UNCONFIRMED };
      }
      return { text: "Probe connection cancelled. No product source was changed." };
    }
    const label = current.schemaVersion === 1 ? " Experimental schema 1 file transport." : "";
    return { ready: true, text: `Comparison-only probe connected.${label} Values arrive on session.measure, not on rereading a cache. Stream: ${current.streamID}` };
  } catch {
    clearUsage(current);
    current.producer = null;
    if ((current.control?.connectConfirmed || operation.abandoned && current.control?.connectAttempted)
      && !(await disconnectControl($, current.control))) {
      state.deadBinding = current.control;
      return { text: DISCONNECT_UNCONFIRMED };
    }
    if (!operation.abandoned && !current.control?.connectConfirmed && current.control?.connectAttempted) state.deadBinding = current.control;
    if (operation.abandoned) return { text: "Probe connection cancelled. No product source was changed." };
    return { text: "Probe connection failed. Prepare a new private comparison directory; no product source was changed." };
  }
}

export function register(on) {
  const state = { active: null, deadBinding: null, handshakePromise: null,
    busy: false, generation: 0, closing: Promise.resolve(true) };

  on("session.start", async ($, event, next) => {
    await stop($, state);
    await $.command.register({ name: COMMAND, description: "Comparison-only QuotaTempo quota probe",
      argumentHint: "connect <prepared absolute directory> <app public key> | disconnect | status", immediate: true });
    return next(event);
  });

  on("command.run", { command: COMMAND }, async ($, event, next) => {
    const signal = next?.signal;
    if (signal?.aborted) return { text: "Probe connection cancelled. No product source was changed." };
    const args = (event.args ?? "").trim();
    if (args === "disconnect") {
      const confirmed = await stop($, state);
      return { text: confirmed ? "QuotaTempo probe disconnected. No product source was changed." : DISCONNECT_UNCONFIRMED };
    }
    if (args === "status") {
      return { text: state.active ? `Comparison-only probe connected. Stream: ${state.active.streamID}`
        : state.deadBinding ? DISCONNECT_UNCONFIRMED : "QuotaTempo probe disconnected." };
    }
    if (!args.startsWith("connect ")) return { text: "Copy the prepared connect command from QuotaTempo, or use disconnect or status." };
    if (state.busy) return { text: "Probe export is in progress. Connection was not changed." };
    const generation = state.generation + 1;
    const operation = { abandoned: false };
    // A retired command may fence only its own setup, never a later generation.
    const abandon = () => {
      operation.abandoned = true;
      if (state.generation === generation) state.generation++;
    };
    signal?.addEventListener("abort", abandon, { once: true });
    try {
      await stop($, state);
      if (state.generation !== generation) return { text: "Probe connection cancelled. No product source was changed." };
      const input = args.slice(8).trim();
      const pinned = /^(\/private\/tmp\/qtc-[0-9a-f-]{36}) ([0-9a-f]{64})$/.exec(input);
      const directory = pinned ? pinned[1] : input;
      const publicKey = pinned ? pinned[2] : null;
      if (!validDirectory(directory) || !(await directoryIsSafe($, directory))) throw new Error();
      const grantPath = `${directory}/probe-grant.json`;
      if (!(await writeIsSafe($, grantPath))) throw new Error();
      const stat = await $.fs.stat(grantPath);
      if (stat.size > 1024) throw new Error();
      const grantText = await $.fs.read(grantPath);
      const grant = decodeGrant(grantText, await $.clock.now(), directory);
      if (!grant) throw new Error();
      if ((grant.schemaVersion === 3 && !publicKey) || (grant.schemaVersion === 1 && publicKey)) throw new Error();
      const id = streamID();
      const path = `${directory}/stream-${id}.json`;
      // Never take over another stream or overwrite an existing export.
      if (grant.schemaVersion === 1 && await $.fs.exists(path)) throw new Error();
      const current = { directory, path, grantText, publicKey, schemaVersion: grant.schemaVersion, socketPath: grant.socketPath,
        connectionID: grant.connectionID, streamID: id, sequence: 0, usage: null,
        readAt: null, pending: Promise.resolve(), latest: null, measureOrder: 0, latestOrder: 0 };
      current.producer = createUsageProducer({ getUsage: () => current.usage,
        clock: () => current.readAt, sink: () => {} });
      if (current.schemaVersion === 3) {
        // Control-only state survives a failed measurement; never retain quota for replay.
        current.control = { directory, grantText, publicKey, socketPath: current.socketPath,
          connectionID: current.connectionID, streamID: id, pending: current.pending,
          connectAttempted: false, connectConfirmed: false,
          disconnectAttempted: false, disconnectConfirmed: false };
      }
      if (state.generation !== generation) return { text: "Probe connection cancelled. No product source was changed." };
      let completed;
      const handshake = new Promise(resolve => { completed = resolve; });
      if (current.control) state.handshakePromise = handshake;
      const connecting = finishConnection($, state, current, generation, operation);
      try {
        const { ready, ...reply } = await connecting;
        if (ready) {
          // Activate only in the command's final synchronous section, with no
          // await between this fence and removal of its abandonment listener.
          if (state.generation !== generation) {
            clearUsage(current);
            current.producer = null;
            if (current.control && !(await disconnectControl($, current.control))) {
              state.deadBinding = current.control;
              return { text: DISCONNECT_UNCONFIRMED };
            }
            return { text: "Probe connection cancelled. No product source was changed." };
          }
          if (current.control) state.deadBinding = null;
          state.active = current;
        }
        return reply;
      } finally {
        completed();
        if (state.handshakePromise === handshake) state.handshakePromise = null;
      }
    } catch {
      if (operation.abandoned) return { text: "Probe connection cancelled. No product source was changed." };
      return { text: "Probe connection failed. Prepare a new private comparison directory; no product source was changed." };
    } finally {
      signal?.removeEventListener("abort", abandon);
    }
  });

  on("session.measure", async ($, event, next) => {
    if (state.active) {
      const current = state.active;
      const order = ++current.measureOrder;
      try {
        const readAt = new Date(await $.clock.now()).toISOString();
        if (state.active === current && order > current.latestOrder) {
          current.latestOrder = order;
          current.latest = { readAt, rateLimits: event.rateLimits };
          if (!state.busy) {
            state.busy = true;
            current.pending = deliver($, state, current);
            if (current.control) current.control.pending = current.pending;
          }
        }
      } catch {
        if (state.active === current) {
          state.active = null;
          clearUsage(current);
          current.producer = null;
          if (current.control) state.deadBinding = current.control;
          await current.pending;
          if (current.schemaVersion === 1) {
            try {
              await writeResult($, current, { schemaVersion: 1, status: "unavailable",
                reason: "clock_failed", readAt: null, rateLimits: [] });
            } catch {}
          }
        }
      }
      await current.pending;
    }
    return next(event);
  });

  on("session.end", async ($, event, next) => {
    await stop($, state);
    return next(event);
  });
}
