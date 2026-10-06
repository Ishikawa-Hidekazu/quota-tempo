// Synthetic real-engine wire acceptance only; never provider or signed-app acceptance.
// Usage: node official-ipc-client.mjs <native directory> <epoch milliseconds> <app public key> <absolute CLI>
import fs from "node:fs/promises";
import { constants } from "node:fs";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import os from "node:os";
import net from "node:net";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const SHA256 = "03d66745e3bb69ec727d66023696f3820bc0a00a8a5ba725eb6706d0c67cbe69";
const FILES = Object.freeze([
  ".claude-plugin/plugin.json", ".claude-plugin/marketplace.json",
  "hooks/hooks.json", "hooks/register.mjs", "producer.mjs", "protocol.mjs",
  "transport-crypto.mjs", "THIRD_PARTY_NOTICES.txt",
]);
const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";
const SOURCE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const LIMIT = 256 * 1024;
class Failure extends Error {}
function requireCondition(value, reason) { if (!value) throw new Failure(reason); }
function same(a, b) { return a.dev === b.dev && a.ino === b.ino && a.uid === b.uid; }

function engineReply(output) {
  let reply;
  try { reply = JSON.parse(output); } catch { throw new Failure("unsupportedEngineAPI"); }
  requireCondition(reply.type === "result" && reply.subtype === "success" && reply.is_error === false
    && reply.num_turns === 0 && reply.total_cost_usd === 0
    && reply.modelUsage && Object.keys(reply.modelUsage).length === 0
    && typeof reply.result === "string" && reply.result.length <= 1024, "unsupportedEngineAPI");
  return reply.result;
}

async function regular(filename, maximum) {
  const before = await fs.lstat(filename);
  requireCondition(before.isFile() && !before.isSymbolicLink() && before.nlink === 1
    && before.size <= maximum, "unsafeInput");
  const handle = await fs.open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const opened = await handle.stat();
    requireCondition(same(before, opened) && opened.size === before.size, "unsafeInput");
    const bytes = await handle.readFile();
    const after = await handle.stat();
    requireCondition(bytes.length <= maximum && same(opened, await fs.lstat(filename))
      && opened.mtimeMs === after.mtimeMs && opened.ctimeMs === after.ctimeMs, "unsafeInput");
    return bytes;
  } finally { await handle.close(); }
}

export function sandboxPolicy(home, socketPath) {
  // Apple application.sb uses literal/subpath network-outbound filters for Unix sockets.
  // No remote IP, DNS, inbound, bind or other Unix endpoint is permitted.
  return `(version 1) (allow default)
    (deny network*)
    (allow network-outbound (literal ${JSON.stringify(socketPath)}))
    (deny network-outbound (remote tcp) (remote udp))
    (deny file-read* file-write* (subpath ${JSON.stringify(home)}))`;
}

export function fixtureModule(source, directory, now, publicKey) {
  // Only the private register.mjs copy is instrumented. Seven copied files stay
  // byte-identical, including hooks.json; no fixture module/crypto imports exist.
  const edits = [];
  const replace = (before, after) => {
    requireCondition(source.split(before).length === 2, "instrumentationMismatch");
    source = source.replace(before, after);
    edits.push({ before, after });
  };
  const original = source;
  const commandStart = '  on("command.run", { command: COMMAND }, async ($, event, next) => {';
  const measureStart = '  on("session.measure", async ($, event, next) => {';
  const endStart = '  on("session.end", async ($, event, next) => {';
  const functions = [];
  const extract = (start, following, name, registration) => {
    requireCondition(source.split(start).length === 2, "instrumentationMismatch");
    const begin = source.indexOf(start);
    const ending = `\n  });\n\n${following}`;
    const end = source.indexOf(ending, begin + start.length);
    requireCondition(end > begin, "instrumentationMismatch");
    const block = source.slice(begin, end + '\n  });'.length);
    const body = source.slice(begin + start.length, end);
    functions.push(`async function ${name}($, event, next, state) {${body}\n}\n`);
    replace(block, registration);
  };
  extract(commandStart, measureStart, "fixtureCommand",
    '  on("command.run", { command: COMMAND }, async ($, event, next) => fixtureCommand($, event, next, state));');
  extract(measureStart, endStart, "fixtureMeasure",
    '  on("session.measure", async ($, event, next) => fixtureMeasure($, event, next, state));');
  // The official compiler allows $ forwarding only to file-level functions.
  // Original handler bodies are unchanged; their closed-over state is explicit.
  replace("export function register(on) {", `${functions.join("\n")}\nexport function register(on) {`);
  const registration = '    await $.command.register({ name: COMMAND, description: "Comparison-only QuotaTempo quota probe",';
  replace(registration, `    await $.command.register({ name: "qtc-native-fixture", description: "Synthetic wire fixture", immediate: true });\n${registration}`);
  const fixture = `
  // Fail closed before a model turn, including when command loading fails.
  on("prompt.submit", async ($, event, next) => {
    if (["/qtc-native-fixture", "/qtc-native-fixture status", "/quotatempo-probe status"].includes(event.text.trim())) return next(event);
    return { drop: "fixtureUnsupported" };
  });
  on("turn.start", async ($, event, next) => { throw new Error("fixtureModelForbidden"); });
  on("model.complete", async ($, event, next) => ({ deny: "fixtureModelForbidden" }));
  on("model.fork", async ($, event, next) => ({ deny: "fixtureModelForbidden" }));
  on("model.classify", async ($, event, next) => ({ deny: "fixtureModelForbidden" }));
  on("command.run", { command: "qtc-native-fixture" }, async ($, event, next) => {
    if (event.args === "status") return { text: "fixturePrepared" };
    if ((event.args ?? "").trim() !== "") return { text: "fixtureUnsupported" };
    let attempted = false;
    let validated = false;
    let disconnected = false;
    try {
      attempted = true;
      const connected = await fixtureCommand($, { ...event, command: "quotatempo-probe",
        args: ${JSON.stringify(`connect ${directory} ${publicKey}`)} }, next, state);
      if (!/^Comparison-only probe connected\\. Values arrive on session\\.measure, not on rereading a cache\\. Stream: [0-9a-f-]{36}$/.test(connected?.text ?? ""))
        return { text: "fixtureConnectFailed" };
      // This is inline synthetic event data, not an engine/provider usage read.
      // Its terminal continuation returns the event rather than running core's command.
      await fixtureMeasure($, { rateLimits: [{ kind: "seven_day", percentUsed: 42,
        resetsAt: ${JSON.stringify(new Date(now + 86400000).toISOString())} }] }, async input => input, state);
      const status = await fixtureCommand($, { ...event, command: "quotatempo-probe", args: "status" }, next, state);
      if (!/^Comparison-only probe connected\\. Stream: [0-9a-f-]{36}$/.test(status?.text ?? ""))
        return { text: "fixtureMeasureFailed" };
      await $.clock.sleep(3000);
      validated = true;
    } catch { return { text: "fixtureUnsupported" }; }
    finally {
      if (attempted) {
        try {
          const result = await fixtureCommand($, { ...event, command: "quotatempo-probe", args: "disconnect" }, next, state);
          disconnected = result?.text === "QuotaTempo probe disconnected. No product source was changed.";
        } catch {}
      }
    }
    return { text: validated && disconnected ? "fixtureValidated" : "fixtureDisconnectFailed" };
  });
`;
  const end = "    await stop($, state);\n    return next(event);\n  });\n}";
  replace(end, end.replace("\n}", `${fixture}\n}`));
  let reversed = source;
  for (const { before, after } of edits.toReversed()) {
    requireCondition(reversed.split(after).length === 2, "instrumentationMismatch");
    reversed = reversed.replace(after, before);
  }
  requireCondition(reversed === original, "instrumentationMismatch");
  return source;
}

// Only this detached process group is signalled. Child output is bounded and never relayed.
async function child(file, args, { cwd, env, deadline = 15000, signal } = {}) {
  requireCondition(!signal?.aborted, "interrupted");
  return new Promise((resolve, reject) => {
    const processChild = spawn(file, args, { cwd, env, detached: true, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "", bytes = 0, failure = null, killTimer;
    const kill = how => {
      if (!processChild.pid) return;
      try { process.kill(-processChild.pid, how); } catch (error) {
        if (error.code !== "ESRCH") failure ??= "terminationFailed";
      }
    };
    const stop = reason => {
      if (failure) return;
      failure = reason;
      kill("SIGTERM");
      killTimer = setTimeout(() => kill("SIGKILL"), 250);
    };
    const interrupt = () => stop("interrupted");
    signal?.addEventListener("abort", interrupt, { once: true });
    const timer = setTimeout(() => stop("deadlineExceeded"), deadline);
    const collect = destination => chunk => {
      bytes += chunk.length;
      if (bytes > LIMIT) { stop("outputLimitExceeded"); return; }
      if (destination === "stdout") stdout += chunk.toString("utf8");
      else stderr += chunk.toString("utf8");
    };
    processChild.stdout.on("data", collect("stdout"));
    processChild.stderr.on("data", collect("stderr"));
    processChild.once("error", () => { failure ??= "launchFailed"; });
    processChild.once("exit", () => kill("SIGKILL"));
    processChild.once("close", code => {
      clearTimeout(timer); clearTimeout(killTimer);
      signal?.removeEventListener("abort", interrupt);
      if (failure) reject(new Failure(failure));
      else resolve({ code, stdout, stderr });
    });
  });
}

async function validateNative(directory) {
  const info = await fs.lstat(directory);
  requireCondition(info.isDirectory() && !info.isSymbolicLink() && info.uid === process.getuid()
    && (info.mode & 0o7777) === 0o700 && await fs.realpath(directory) === directory, "unsafeInput");
  const socket = await fs.lstat(`${directory}/bridge.sock`);
  requireCondition(socket.isSocket() && socket.uid === process.getuid()
    && (socket.mode & 0o7777) === 0o600, "unsafeInput");
  const grant = await fs.lstat(`${directory}/probe-grant.json`);
  requireCondition(grant.uid === process.getuid() && (grant.mode & 0o7777) === 0o600, "unsafeInput");
  const text = await regular(`${directory}/probe-grant.json`, 1024);
  const value = JSON.parse(text);
  requireCondition(value.schemaVersion === 3 && value.transport === "unix-hpke"
    && value.socketPath === `${directory}/bridge.sock`, "unsafeInput");
}

export async function runOfficialIPC(args, { signal } = {}) {
  let root, rootInfo, forbiddenServer;
  let result = { status: "failed", error: true };
  try {
    const [directory, timeText, publicKey, executable, extra] = args;
    const now = Number(timeText);
    requireCondition(process.platform === "darwin" && extra === undefined && typeof directory === "string"
      && new RegExp(`^/private/tmp/qtc-${UUID}$`).test(directory)
      && typeof timeText === "string" && timeText.trim() !== "" && Number.isFinite(now)
      && Number.isFinite(new Date(now + 86400000).getTime())
      && typeof publicKey === "string" && /^[0-9a-f]{64}$/.test(publicKey)
      && typeof executable === "string" && path.isAbsolute(executable)
      && !/[\x00-\x1f\\]/.test(executable)
      && !executable.split("/").some(part => part === "." || part === "..")
      && !executable.startsWith(`${os.homedir()}/`), "invalidArguments");
    await validateNative(directory);
    const cliInfo = await fs.lstat(executable);
    requireCondition(cliInfo.uid === process.getuid() && (cliInfo.mode & 0o022) === 0
      && await fs.realpath(executable) === executable, "binaryRejected");
    requireCondition(createHash("sha256").update(await regular(executable, 300 * 1024 * 1024)).digest("hex") === SHA256,
      "binaryRejected");
    const signing = await child("/usr/bin/codesign", ["--verify", "--strict", executable],
      { env: { PATH: "/usr/bin:/bin" }, signal });
    requireCondition(signing.code === 0, "binaryRejected");
    root = await fs.mkdtemp("/private/tmp/qtc-official-ipc-");
    await fs.chmod(root, 0o700);
    rootInfo = await fs.lstat(root);
    const plugin = path.join(root, "plugin");
    for (const name of ["plugin", "plugin/.claude-plugin", "plugin/hooks", "home", "tmp", "project"])
      await fs.mkdir(path.join(root, name), { mode: 0o700 });
    for (const relative of FILES)
      await fs.writeFile(path.join(plugin, relative), await regular(path.join(SOURCE, relative), LIMIT),
        { mode: 0o600, flag: "wx" });
    const env = { HOME: path.join(root, "home"), TMPDIR: path.join(root, "tmp"),
      PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LANG: "en_US.UTF-8",
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1", DISABLE_AUTOUPDATER: "1" };
    const policy = sandboxPolicy(os.homedir(), `${directory}/bridge.sock`);
    const options = { env, cwd: path.join(root, "project"), signal };
    // Copy Node itself because the caller's executable can reside under denied normal HOME.
    // No normal-HOME contents/configuration are passed to the engine.
    const node = path.join(root, "node");
    await fs.copyFile(process.execPath, node, constants.COPYFILE_EXCL);
    await fs.chmod(node, 0o700);
    // An existing off-policy socket is needed: missing paths can return ENOENT
    // before the sandbox check, which cannot prove that Unix access was denied.
    forbiddenServer = net.createServer(socket => socket.destroy());
    await new Promise((resolve, reject) => {
      forbiddenServer.once("error", reject);
      forbiddenServer.listen(`${root}/forbidden.sock`, resolve);
    });
    const safety = await child("/usr/bin/sandbox-exec", ["-p", policy, node, "--input-type=module", "-e", `
      import net from "node:net"; import dgram from "node:dgram"; import fs from "node:fs/promises";
      const denied = error => error && ["EPERM", "EACCES"].includes(error.code);
      const tcp = await new Promise(resolve => {
        const socket = net.connect({host:"127.0.0.1",port:9});
        socket.on("error", error => resolve(denied(error)));
        socket.on("connect", () => { socket.destroy(); resolve(false); });
        socket.setTimeout(1000, () => { socket.destroy(); resolve(false); });
      });
      const udp = await new Promise(resolve => {
        const socket = dgram.createSocket("udp4");
        socket.on("error", error => { socket.close(); resolve(denied(error)); });
        socket.send(Buffer.from("synthetic"), 9, "127.0.0.1", error => { socket.close(); resolve(denied(error)); });
      });
      const unix = await new Promise(resolve => {
        const socket = net.connect(${JSON.stringify(`${root}/forbidden.sock`)});
        socket.on("error", error => resolve(denied(error)));
        socket.on("connect", () => { socket.destroy(); resolve(false); });
        socket.setTimeout(1000, () => { socket.destroy(); resolve(false); });
      });
      let home = false;
      try { await fs.stat(${JSON.stringify(os.homedir())}); } catch (error) { home = denied(error); }
      process.stdout.write(tcp && udp && unix && home ? "policyValidated" : "policyRejected");
    `], { ...options, deadline: 5000 });
    requireCondition(safety.code === 0 && safety.stdout === "policyValidated", "unsupportedPolicy");
    await new Promise(resolve => forbiddenServer.close(resolve));
    forbiddenServer = null;
    // Prove the engine's existing immediate control command works before synthetic measurement.
    const cliStarted = Date.now();
    const cliBudget = () => {
      const remaining = 20000 - (Date.now() - cliStarted);
      requireCondition(remaining > 0, "deadlineExceeded");
      return remaining;
    };
    const control = await child("/usr/bin/sandbox-exec", ["-p", policy, executable,
      "-p", "/quotatempo-probe status", "--plugin-dir", plugin, "--strict-mcp-config", "--output-format", "json"],
      { ...options, deadline: cliBudget() });
    requireCondition(control.code === 0,
      /(?:log.?in|authentication|not authenticated|API key)/i.test(control.stdout + control.stderr)
        ? "engineAuthGate" : "unsupportedEngineAPI");
    const controlText = engineReply(control.stdout);
    const disconnectedText = "QuotaTempo probe disconnected.";
    requireCondition(controlText.endsWith(disconnectedText)
      && controlText.indexOf(disconnectedText) === controlText.lastIndexOf(disconnectedText), "unsupportedEngineAPI");
    // The official print-mode command result can include a presentation prefix.
    // Pin that control-only prefix, then require exact fixture reply equality.
    const replyPrefix = controlText.slice(0, -disconnectedText.length);
    requireCondition(replyPrefix.length <= 128 && /^[A-Za-z ():_-]*$/.test(replyPrefix), "unsupportedEngineAPI");
    const registerCopy = path.join(plugin, "hooks/register.mjs");
    await fs.writeFile(registerCopy,
      fixtureModule((await regular(registerCopy, LIMIT)).toString("utf8"), directory, now, publicKey));
    const validation = await child("/usr/bin/sandbox-exec", ["-p", policy, executable,
      "plugin", "validate", plugin], { ...options, deadline: cliBudget() });
    requireCondition(validation.code === 0, "unsupportedEngineAPI");
    const prepared = await child("/usr/bin/sandbox-exec", ["-p", policy, executable,
      "-p", "/qtc-native-fixture status", "--plugin-dir", plugin, "--strict-mcp-config", "--output-format", "json"],
      { ...options, deadline: cliBudget() });
    requireCondition(prepared.code === 0 && engineReply(prepared.stdout) === `${replyPrefix}fixturePrepared`,
      "unsupportedEngineAPI");
    const engine = await child("/usr/bin/sandbox-exec", ["-p", policy, executable,
      "-p", "/qtc-native-fixture", "--plugin-dir", plugin, "--strict-mcp-config", "--output-format", "json"],
      { ...options, deadline: cliBudget() });
    const selected = engine.code === 0 ? engineReply(engine.stdout) : "";
    requireCondition(engine.code === 0 && selected === `${replyPrefix}fixtureValidated`,
      /(?:log.?in|authentication|not authenticated|API key)/i.test(engine.stdout + engine.stderr)
        ? "engineAuthGate" : selected === `${replyPrefix}fixtureConnectFailed` ? "connectFailed"
          : selected === `${replyPrefix}fixtureMeasureFailed` ? "measureFailed"
            : selected === `${replyPrefix}fixtureDisconnectFailed` ? "disconnectFailed" : "unsupportedEngineAPI");
    result = { status: "passed", actualHTTP: true, modelRequests: 0,
      quotaFileWrites: 0, liveAcceptance: false };
  } catch (error) {
    const reasons = ["invalidArguments", "unsafeInput", "binaryRejected", "unsupportedPolicy",
      "engineAuthGate", "connectFailed", "measureFailed", "disconnectFailed", "unsupportedEngineAPI",
      "deadlineExceeded", "outputLimitExceeded", "launchFailed", "terminationFailed", "interrupted", "instrumentationMismatch"];
    result = { status: "failed", error: true,
      [error instanceof Failure && reasons.includes(error.message) ? error.message : "localFailure"]: true };
  } finally {
    if (forbiddenServer) await new Promise(resolve => forbiddenServer.close(resolve));
    if (root) {
      try {
        const current = await fs.lstat(root);
        requireCondition(rootInfo && same(rootInfo, current) && current.isDirectory()
          && !current.isSymbolicLink() && current.uid === process.getuid()
          && (current.mode & 0o7777) === 0o700 && await fs.realpath(root) === root, "unsafeInput");
        await fs.rm(root, { recursive: true });
      } catch { result = { status: "failed", error: true, cleanupIncomplete: true }; }
    }
  }
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  process.on("SIGINT", interrupt); process.on("SIGTERM", interrupt);
  const result = await runOfficialIPC(process.argv.slice(2), { signal: controller.signal });
  process.off("SIGINT", interrupt); process.off("SIGTERM", interrupt);
  process.stdout.write(`${JSON.stringify(result)}\n`);
  process.exitCode = result.status === "passed" ? 0 : 1;
}
