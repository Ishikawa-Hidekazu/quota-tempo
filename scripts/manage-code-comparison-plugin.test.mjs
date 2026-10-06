import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { spawnSync } from "node:child_process";
import { packPlugin, PLUGIN_FILES } from "./package-code-comparison-plugin.mjs";
import { applyManagement, planManagement, runCommand } from "./manage-code-comparison-plugin.mjs";

const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../experiments/claude-mods-usage");
const manager = fileURLToPath(new URL("./manage-code-comparison-plugin.mjs", import.meta.url));
const currentVersion = JSON.parse(fs.readFileSync(path.join(source, ".claude-plugin/plugin.json"), "utf8")).version;
const nextVersion = currentVersion.split(".").map((part, index) => index === 2 ? Number(part) + 1 : part).join(".");

async function fixture(t) {
  const root = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), "quotatempo-manager-"));
  fs.chmodSync(root, 0o700);
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const project = path.join(root, "project with spaces");
  fs.mkdirSync(project, { mode: 0o700 });
  const executable = path.join(root, "claude");
  fs.writeFileSync(executable, "#!/bin/sh\nprintf '2.1.289 (Claude Code)\\n'\n", { mode: 0o700 });
  const packageDirectory = path.join(root, "plugin");
  await packPlugin({ source, destination: packageDirectory });
  const calls = [];
  const runner = async (file, argv, cwd) => { calls.push({ file, argv, cwd }); return { ok: true }; };
  const options = { action: "install", project, executable, packageDirectory,
    receiptDirectory: path.join(root, "receipt"), consentLocalManagement: true, sessionsClosed: true };
  return { root, calls, runner, options };
}

async function nextPackage(root) {
  const staged = path.join(root, "next-source"); fs.mkdirSync(staged, { mode: 0o700 });
  for (const relative of PLUGIN_FILES) {
    const destination = path.join(staged, relative);
    fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
    fs.copyFileSync(path.join(source, relative), destination); fs.chmodSync(destination, 0o600);
  }
  for (const relative of [".claude-plugin/plugin.json", ".claude-plugin/marketplace.json"]) {
    const file = path.join(staged, relative), metadata = JSON.parse(fs.readFileSync(file, "utf8"));
    if (relative.endsWith("/plugin.json")) metadata.version = nextVersion;
    else {
      metadata.metadata.version = nextVersion;
      for (const plugin of metadata.plugins) if (plugin.version) plugin.version = nextVersion;
    }
    fs.writeFileSync(file, JSON.stringify(metadata));
  }
  const destination = path.join(root, "next-package");
  await packPlugin({ source: staged, destination });
  return destination;
}

test("planning makes no receipt or CLI mutation and fixes local scope", async t => {
  const { options } = await fixture(t);
  const plan = await planManagement(options);
  assert.equal(fs.existsSync(options.receiptDirectory), false);
  assert.equal(plan.commands.length, 2);
  assert.deepEqual(plan.commands[0].slice(-2), ["--scope", "local"]);
  assert.deepEqual(plan.commands[1].slice(-2), ["--scope", "local"]);
  assert.match(plan.pluginID, /^quotatempo-usage-probe@quotatempo-code-/);
});

test("public consent install records only metadata and never submits a turn", async t => {
  const { options, runner, calls } = await fixture(t);
  assert.equal((await applyManagement(options, { runner })).status, "ready");
  assert.equal(calls.length, 3);
  assert.equal(calls.every(call => call.cwd === options.project), true);
  assert.equal(calls.every(call => call.file === options.executable), true);
  assert.equal(calls.slice(1).every(call => call.argv[0] === "plugin"), true);
  const receipt = JSON.parse(fs.readFileSync(path.join(options.receiptDirectory, "receipt.json"), "utf8"));
  assert.equal(receipt.completedSteps, 2);
  assert.equal(receipt.pendingStep, null);
  assert.equal(receipt.status, "ready");
  assert.equal(fs.statSync(path.join(options.receiptDirectory, "receipt.json")).mode & 0o777, 0o600);
  assert.equal(fs.existsSync(path.join(options.receiptDirectory, "operation.lock")), false);
  assert.equal(Object.keys(receipt).some(key => /stdout|stderr|auth|token|cookie/.test(key)), false);
});

for (const missing of ["consentLocalManagement", "sessionsClosed"]) {
  for (const value of [undefined, false, "true", 1]) {
    test(`requires boolean true ${missing} acknowledgement, not ${String(value)}`, async t => {
      const { options, calls, runner } = await fixture(t);
      options[missing] = value;
      await assert.rejects(applyManagement(options, { runner }), /explicit_trial_ack_required/);
      assert.equal(calls.length, 0);
      assert.equal(fs.existsSync(options.receiptDirectory), false);
      assert.equal(fs.existsSync(path.join(options.project, ".quotatempo-code-plugin-management")), false);
    });
  }
}

test("legacy localTrial consent still permits a synthetic install", async t => {
  const { options, calls, runner } = await fixture(t);
  delete options.consentLocalManagement;
  options.localTrial = true;
  assert.equal((await applyManagement(options, { runner })).status, "ready");
  assert.equal(calls.length, 3);
});

test("legacy localTrial consent cannot bypass the closed-session requirement", async t => {
  const { options, calls, runner } = await fixture(t);
  delete options.consentLocalManagement;
  options.localTrial = true;
  options.sessionsClosed = false;
  await assert.rejects(applyManagement(options, { runner }), /explicit_trial_ack_required/);
  assert.equal(calls.length, 0);
  assert.equal(fs.existsSync(options.receiptDirectory), false);
  assert.equal(fs.existsSync(path.join(options.project, ".quotatempo-code-plugin-management")), false);
});

function invokeCLI(options, flags) {
  const result = spawnSync(process.execPath, [manager, options.action,
    "--project", options.project, "--cli", options.executable,
    "--package", options.packageDirectory, "--receipt", options.receiptDirectory, ...flags],
  { encoding: "utf8", timeout: 10000 });
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  assert.equal(result.stderr, "");
  return { exitCode: result.status, report: JSON.parse(result.stdout) };
}

for (const consentProvided of [false, true]) {
  test(`CLI stays plan-only without apply, public consent ${consentProvided}`, async t => {
    const { options } = await fixture(t);
    const flags = consentProvided ? ["--consent-local-management", "--code-sessions-closed"] : [];
    const { exitCode, report } = invokeCLI(options, flags);
    assert.equal(exitCode, 0);
    assert.equal(report.status, "planOnly");
    assert.equal(report.requiresExplicitConsent, true);
    assert.equal(report.requiresClosedSessions, true);
    assert.equal(Object.hasOwn(report, "localTrialOnly"), false);
    assert.deepEqual(report.commands, (await planManagement(options)).commands);
    assert.equal(fs.existsSync(options.receiptDirectory), false);
    assert.equal(fs.existsSync(path.join(options.project, ".quotatempo-code-plugin-management")), false);
  });
}

for (const acknowledgement of ["--consent-local-management", "--code-sessions-closed"]) {
  test(`CLI cannot apply with only ${acknowledgement}`, async t => {
    const { options } = await fixture(t);
    const { exitCode, report } = invokeCLI(options, ["--apply", acknowledgement]);
    assert.equal(exitCode, 1);
    assert.deepEqual(report, { status: "stopped", reason: "explicit_trial_ack_required" });
    assert.equal(fs.existsSync(options.receiptDirectory), false);
    assert.equal(fs.existsSync(path.join(options.project, ".quotatempo-code-plugin-management")), false);
  });
}

for (const acknowledgement of ["--consent-local-management", "--local-trial"]) {
  test(`CLI accepts ${acknowledgement} for synthetic local install only`, async t => {
    const { options } = await fixture(t);
    const { exitCode, report } = invokeCLI(options, ["--apply", acknowledgement, "--code-sessions-closed"]);
    assert.equal(exitCode, 0);
    assert.deepEqual(report, { status: "ready", completedSteps: 2, runtimeAccepted: false,
      marketplacesRetained: true });
    const receipt = JSON.parse(fs.readFileSync(path.join(options.receiptDirectory, "receipt.json"), "utf8"));
    assert.equal(receipt.status, "ready");
    assert.equal(receipt.completedSteps, 2);
  });
}

test("incompatible CLI stops before any plugin management", async t => {
  const { options, calls } = await fixture(t);
  await assert.rejects(applyManagement(options, { runner: async (_, argv) => { calls.push(argv); return { ok: false }; } }), /compatible_cli_required/);
  assert.deepEqual(calls, [["--version"]]);
});

test("uncertain second step is persisted and never automatically replayed", async t => {
  const { options, calls } = await fixture(t);
  const result = await applyManagement(options, { runner: async (_, argv) => {
    calls.push(argv);
    if (argv[1] === "install") throw new Error("private diagnostic must not be copied");
    return { ok: true };
  } });
  assert.deepEqual(result, { status: "attentionRequired", completedSteps: 1, retryAllowed: false });
  const text = fs.readFileSync(path.join(options.receiptDirectory, "receipt.json"), "utf8");
  assert.equal(text.includes("private diagnostic"), false);
  assert.equal(JSON.parse(text).pendingStep, 1);
  await assert.rejects(applyManagement({ ...options, action: "uninstall" }, { runner: async () => assert.fail("must not replay") }), /reconciliation_required/);
});

for (const action of ["disable", "enable", "update", "uninstall"]) {
  test(`${action} uses the exact qualified ID and explicit local scope`, async t => {
    const { options, runner, calls } = await fixture(t);
    await applyManagement(options, { runner });
    if (action === "enable") await applyManagement({ ...options, action: "disable" }, { runner });
    calls.length = 0;
    const result = await applyManagement({ ...options, action }, { runner });
    assert.equal(calls.length, 2);
    assert.equal(calls[1].argv[1], action);
    assert.match(calls[1].argv[2], /^quotatempo-usage-probe@quotatempo-code-/);
    assert.deepEqual(calls[1].argv.slice(3, 5), ["--scope", "local"]);
    assert.equal(calls.some(call => call.argv.includes("remove") || call.argv.includes("prune")), false);
    assert.equal(result.marketplacesRetained, true);
    assert.equal(result.runtimeAccepted, false);
  });
}

function journalSnapshot(options) {
  return [path.join(options.receiptDirectory, "receipt.json"),
    path.join(options.project, ".quotatempo-code-plugin-management", "state.json")].map(file => {
    const stat = fs.statSync(file);
    return { text: fs.readFileSync(file, "utf8"), inode: stat.ino, modified: stat.mtimeMs };
  });
}

test("enable plans only the disabled exact managed ID and journals its transition", async t => {
  const { options, runner, calls } = await fixture(t);
  await applyManagement(options, { runner });
  await applyManagement({ ...options, action: "disable" }, { runner });
  const before = journalSnapshot(options);
  const disabled = JSON.parse(before[0].text);
  calls.length = 0;
  const enable = { ...options, action: "enable" };
  const plan = await planManagement(enable);
  assert.deepEqual(plan.commands, [["plugin", "enable", disabled.pluginID, "--scope", "local"]]);
  assert.deepEqual(journalSnapshot(options), before);
  assert.equal(calls.length, 0);
  assert.equal((await applyManagement(enable, { runner })).status, "ready");
  assert.deepEqual(calls.map(call => call.argv), [["--version"], ...plan.commands]);
  const record = JSON.parse(journalSnapshot(options)[0].text);
  assert.equal(record.action, "enable");
  assert.equal(record.completedSteps, 1);
  assert.equal(record.pendingStep, null);
  assert.deepEqual(record.previousBinding, { ...disabled.activeBinding });
  assert.deepEqual(record.activeBinding, { ...disabled.activeBinding, status: "ready" });
  assert.deepEqual(record.retainedPluginIDs, disabled.retainedPluginIDs);
  assert.deepEqual(record.steps, [{ command: "enable", pluginID: disabled.pluginID, status: "complete" }]);
  const { receiptDirectory, ...canonical } = JSON.parse(journalSnapshot(options)[1].text);
  assert.equal(receiptDirectory, options.receiptDirectory);
  assert.deepEqual(canonical, record);
});

test("ready enable rejects without a CLI preflight or journal mutation", async t => {
  const { options, runner, calls } = await fixture(t);
  await applyManagement(options, { runner });
  calls.length = 0;
  const before = journalSnapshot(options);
  await assert.rejects(planManagement({ ...options, action: "enable" }), /plugin_already_enabled/);
  await assert.rejects(applyManagement({ ...options, action: "enable" }, { runner }), /plugin_already_enabled/);
  assert.deepEqual(journalSnapshot(options), before);
  assert.equal(calls.length, 0);
  assert.equal(fs.existsSync(path.join(options.project, ".quotatempo-code-plugin-management", "operation.lock")), false);
});

for (const missing of ["consentLocalManagement", "sessionsClosed"]) {
  test(`enable still requires ${missing} acknowledgement`, async t => {
    const { options, runner, calls } = await fixture(t);
    await applyManagement(options, { runner });
    await applyManagement({ ...options, action: "disable" }, { runner });
    calls.length = 0;
    const before = journalSnapshot(options);
    await assert.rejects(applyManagement({ ...options, action: "enable", [missing]: false }, { runner }),
      /explicit_trial_ack_required/);
    assert.deepEqual(journalSnapshot(options), before);
    assert.equal(calls.length, 0);
  });
}

test("enable rejects a different package, edited receipt, project, CLI and shared lock", async t => {
  const { options, runner, root, calls } = await fixture(t);
  await applyManagement(options, { runner });
  await applyManagement({ ...options, action: "disable" }, { runner });
  calls.length = 0;
  const before = journalSnapshot(options);
  const enable = { ...options, action: "enable" };
  const otherPackage = await nextPackage(root);
  await assert.rejects(applyManagement({ ...enable, packageDirectory: otherPackage }, { runner }), /binding_changed/);
  const otherProject = path.join(root, "other-project"); fs.mkdirSync(otherProject, { mode: 0o700 });
  await assert.rejects(applyManagement({ ...enable, project: otherProject }, { runner }), /project_ledger_mismatch/);
  const otherCLI = path.join(root, "other-cli"); fs.copyFileSync(options.executable, otherCLI);
  await assert.rejects(applyManagement({ ...enable, executable: otherCLI }, { runner }), /binding_changed/);
  const lock = path.join(options.project, ".quotatempo-code-plugin-management", "operation.lock");
  fs.writeFileSync(lock, "", { mode: 0o600 });
  await assert.rejects(applyManagement(enable, { runner }), /operation_locked/);
  fs.unlinkSync(lock);
  assert.deepEqual(journalSnapshot(options), before);
  const receipt = path.join(options.receiptDirectory, "receipt.json");
  const record = JSON.parse(before[0].text); record.status = "ready";
  fs.writeFileSync(receipt, JSON.stringify(record));
  await assert.rejects(applyManagement(enable, { runner }), /project_ledger_mismatch/);
  assert.equal(calls.length, 0);
});

test("enable rechecks the pinned executable after preflight", async t => {
  const { options, runner, calls } = await fixture(t);
  await applyManagement(options, { runner });
  await applyManagement({ ...options, action: "disable" }, { runner });
  calls.length = 0;
  await assert.rejects(applyManagement({ ...options, action: "enable" }, { runner: async (_, argv) => {
    calls.push(argv);
    fs.appendFileSync(options.executable, "\n# changed\n");
    return { ok: true };
  } }), /binding_changed/);
  assert.deepEqual(calls, [["--version"]]);
  await assert.rejects(planManagement({ ...options, action: "enable" }), /reconciliation_required/);
});

for (const terminationUnconfirmed of [false, true]) {
  test(`uncertain enable blocks replay and preserves lock=${terminationUnconfirmed}`, async t => {
    const { options, runner, calls } = await fixture(t);
    await applyManagement(options, { runner });
    await applyManagement({ ...options, action: "disable" }, { runner });
    const disabled = JSON.parse(journalSnapshot(options)[0].text);
    calls.length = 0;
    const result = await applyManagement({ ...options, action: "enable" }, { runner: async (_, argv) => {
      calls.push(argv);
      return argv[1] === "enable" ? { ok: false, terminationUnconfirmed } : { ok: true };
    } });
    assert.deepEqual(result, { status: "attentionRequired", completedSteps: 0, retryAllowed: false });
    assert.deepEqual(calls, [["--version"], ["plugin", "enable", disabled.pluginID, "--scope", "local"]]);
    const before = journalSnapshot(options), record = JSON.parse(before[0].text);
    assert.equal(record.pendingStep, 0);
    assert.equal(record.steps[0].status, "inFlight");
    assert.deepEqual(record.activeBinding, disabled.activeBinding);
    assert.equal(fs.existsSync(path.join(options.project, ".quotatempo-code-plugin-management", "operation.lock")),
      terminationUnconfirmed);
    for (const action of ["enable", "disable", "update", "uninstall", "install"]) {
      await assert.rejects(applyManagement({ ...options, action }, {
        runner: async () => assert.fail("must not replay") }), /reconciliation_required/);
    }
    assert.deepEqual(journalSnapshot(options), before);
  });
}

test("removed plugin cannot enable or replay its install", async t => {
  const { options, runner, calls } = await fixture(t);
  await applyManagement(options, { runner });
  await applyManagement({ ...options, action: "uninstall" }, { runner });
  const before = journalSnapshot(options); calls.length = 0;
  await assert.rejects(applyManagement({ ...options, action: "enable" }, { runner }), /reconciliation_required/);
  await assert.rejects(applyManagement(options, { runner }), /receipt_exists/);
  assert.deepEqual(journalSnapshot(options), before);
  assert.equal(calls.length, 0);
});

test("same-package update preserves disabled status with exact local commands", async t => {
  const { options, runner, calls } = await fixture(t);
  await applyManagement(options, { runner });
  await applyManagement({ ...options, action: "disable" }, { runner });
  const disabled = JSON.parse(journalSnapshot(options)[0].text); calls.length = 0;
  assert.equal((await applyManagement({ ...options, action: "update" }, { runner })).status, "disabled");
  assert.deepEqual(calls.map(call => call.argv), [["--version"],
    ["plugin", "update", disabled.pluginID, "--scope", "local"],
    ["plugin", "disable", disabled.pluginID, "--scope", "local"]]);
  assert.deepEqual(JSON.parse(journalSnapshot(options)[0].text).activeBinding, disabled.activeBinding);
});

test("mocked local lifecycle disables, enables, disables, upgrades and uninstalls", async t => {
  const { options, runner, calls, root } = await fixture(t);
  await applyManagement(options, { runner });
  const oldID = JSON.parse(journalSnapshot(options)[0].text).pluginID;
  calls.length = 0;
  for (const [action, status] of [["disable", "disabled"], ["enable", "ready"], ["disable", "disabled"]]) {
    assert.equal((await applyManagement({ ...options, action }, { runner })).status, status);
  }
  const packageDirectory = await nextPackage(root), upgraded = { ...options, packageDirectory };
  assert.equal((await applyManagement({ ...upgraded, action: "update" }, { runner })).status, "disabled");
  const newID = JSON.parse(journalSnapshot(options)[0].text).pluginID;
  assert.equal((await applyManagement({ ...upgraded, action: "uninstall" }, { runner })).status, "removed");
  assert.deepEqual(calls.filter(call => call.argv[0] !== "--version").map(call => call.argv), [
    ["plugin", "disable", oldID, "--scope", "local"],
    ["plugin", "enable", oldID, "--scope", "local"],
    ["plugin", "disable", oldID, "--scope", "local"],
    ["plugin", "marketplace", "add", packageDirectory, "--scope", "local"],
    ["plugin", "install", newID, "--scope", "local"],
    ["plugin", "disable", newID, "--scope", "local"],
    ["plugin", "uninstall", oldID, "--scope", "local", "--keep-data"],
    ["plugin", "uninstall", newID, "--scope", "local", "--keep-data"],
  ]);
  assert.equal(calls.every(call => call.file === options.executable && call.cwd === options.project), true);
});

test("a receipt cannot be applied in a different project", async t => {
  const { options, runner, root } = await fixture(t);
  await applyManagement(options, { runner });
  const other = path.join(root, "other"); fs.mkdirSync(other, { mode: 0o700 });
  await assert.rejects(planManagement({ ...options, action: "uninstall", project: other }), /project_ledger_mismatch/);
});

test("renamed replacement project does not inherit a receipt", async t => {
  const { options, runner } = await fixture(t);
  await applyManagement(options, { runner });
  fs.renameSync(options.project, options.project + "-old"); fs.mkdirSync(options.project, { mode: 0o700 });
  await assert.rejects(planManagement({ ...options, action: "disable" }), /project_ledger_mismatch/);
});

test("symlinked project and executable are rejected before mutation", async t => {
  const { options, root } = await fixture(t);
  const link = path.join(root, "project-link"); fs.symlinkSync(options.project, link);
  await assert.rejects(planManagement({ ...options, project: link }), /unsafe_path/);
  const cliLink = path.join(root, "cli-link"); fs.symlinkSync(options.executable, cliLink);
  await assert.rejects(planManagement({ ...options, executable: cliLink }), /unsafe_executable/);
});

test("world-writable CLI and receipt parent are rejected", async t => {
  const { options, root } = await fixture(t);
  fs.chmodSync(options.executable, 0o777);
  await assert.rejects(planManagement(options), /unsafe_executable/);
  fs.chmodSync(options.executable, 0o700);
  fs.chmodSync(root, 0o755);
  await assert.rejects(planManagement(options), /unsafe_path/);
});

test("existing operation lock does not permit concurrent CLI commands", async t => {
  const { options, runner } = await fixture(t);
  await applyManagement(options, { runner });
  fs.writeFileSync(path.join(options.project, ".quotatempo-code-plugin-management", "operation.lock"), "", { mode: 0o600 });
  await assert.rejects(applyManagement({ ...options, action: "disable" }, { runner: async () => assert.fail("locked") }), /operation_locked/);
});

test("receipt file permissions and symlink tampering stop management", async t => {
  const { options, runner, root } = await fixture(t);
  await applyManagement(options, { runner });
  const file = path.join(options.receiptDirectory, "receipt.json");
  fs.chmodSync(file, 0o644);
  await assert.rejects(planManagement({ ...options, action: "disable" }), /unsafe_receipt/);
  fs.chmodSync(file, 0o600);
  fs.renameSync(file, path.join(root, "old-receipt")); fs.symlinkSync(path.join(root, "old-receipt"), file);
  await assert.rejects(planManagement({ ...options, action: "disable" }));
});

test("package mutation after planning cannot launch the next mutation", async t => {
  const { options, calls } = await fixture(t);
  await assert.rejects(applyManagement(options, { runner: async (_, argv) => {
    calls.push(argv);
    if (argv[0] === "--version") fs.appendFileSync(path.join(options.packageDirectory, "producer.mjs"), "\n// changed\n");
    return { ok: true };
  } }));
  assert.deepEqual(calls, [["--version"]]);
});

test("real command runner accepts only a bounded compatible version output", async t => {
  const { options } = await fixture(t);
  assert.deepEqual(await runCommand(options.executable, ["--version"], options.project), { ok: true });
  fs.writeFileSync(options.executable, "#!/bin/sh\nprintf '2.1.267 (Claude Code)\\n'\n");
  assert.deepEqual(await runCommand(options.executable, ["--version"], options.project), { ok: false });
  fs.writeFileSync(options.executable, "#!/bin/sh\nprintf '3.0.0 (Claude Code)\\n'\n");
  assert.deepEqual(await runCommand(options.executable, ["--version"], options.project), { ok: false });
});

test("changing the receipt cannot replay an uncertain operation in the same project", async t => {
  const { options, root } = await fixture(t);
  await applyManagement(options, { runner: async (_, argv) => ({ ok: argv[1] !== "install" }) });
  await assert.rejects(applyManagement({ ...options, receiptDirectory: path.join(root, "second-receipt") }, {
    runner: async () => assert.fail("uncertain operation must not replay") }), /reconciliation_required/);
});

test("a second receipt cannot manage an already managed project", async t => {
  const { options, root, runner } = await fixture(t);
  await applyManagement(options, { runner });
  await assert.rejects(applyManagement({ ...options, receiptDirectory: path.join(root, "second-receipt") }, { runner }), /project_already_managed/);
});

test("shared project lock prevents a parallel install with a different receipt", async t => {
  const { options, root } = await fixture(t);
  let reached, release;
  const started = new Promise(resolve => { reached = resolve; });
  const blocked = new Promise(resolve => { release = resolve; });
  const first = applyManagement(options, { runner: async () => { reached(); await blocked; return { ok: true }; } });
  await started;
  try {
    await assert.rejects(applyManagement({ ...options, receiptDirectory: path.join(root, "second-receipt") }, {
      runner: async () => assert.fail("must not launch concurrently") }), /operation_locked|reconciliation_required/);
  } finally { release(); }
  assert.equal((await first).status, "ready");
});

test("SIGTERM-ignoring child is forcibly stopped at the deadline", async t => {
  const { options } = await fixture(t);
  fs.writeFileSync(options.executable, "#!/bin/sh\ntrap '' TERM\n/bin/sleep 30\n");
  const start = performance.now();
  assert.deepEqual(await runCommand(options.executable, ["plugin", "install"], options.project, { timeoutMs: 100 }), { ok: false });
  assert.ok(performance.now() - start < 3000);
});

test("staged update preserves a disabled plugin instead of re-enabling it", async t => {
  const { options, runner, calls, root } = await fixture(t);
  await applyManagement(options, { runner });
  await applyManagement({ ...options, action: "disable" }, { runner });
  const packageDirectory = await nextPackage(root); calls.length = 0;
  const result = await applyManagement({ ...options, action: "update", packageDirectory }, { runner });
  assert.equal(result.status, "disabled");
  assert.deepEqual(calls.slice(1).map(call => call.argv[1]), ["marketplace", "install", "disable", "uninstall"]);
  const record = JSON.parse(fs.readFileSync(path.join(options.receiptDirectory, "receipt.json"), "utf8"));
  assert.equal(record.activeBinding.packageVersion, nextVersion);
  assert.equal(record.activeBinding.status, "disabled");
  assert.equal(record.previousBinding.packageVersion, currentVersion);
});

test("uncertain removal retains the complete old binding and each exact target", async t => {
  const { options, runner, root } = await fixture(t);
  await applyManagement(options, { runner });
  const old = JSON.parse(fs.readFileSync(path.join(options.receiptDirectory, "receipt.json"), "utf8"));
  const packageDirectory = await nextPackage(root);
  const result = await applyManagement({ ...options, action: "update", packageDirectory }, {
    runner: async (_, argv) => ({ ok: argv[1] !== "uninstall" }) });
  assert.equal(result.status, "attentionRequired");
  const record = JSON.parse(fs.readFileSync(path.join(options.receiptDirectory, "receipt.json"), "utf8"));
  assert.deepEqual(record.activeBinding, old.activeBinding);
  assert.equal(record.previousBinding.packageDigest, old.packageDigest);
  assert.equal(record.previousBinding.packageDirectory, old.packageDirectory);
  assert.equal(record.steps[2].pluginID, old.pluginID);
  assert.equal(record.steps[2].status, "inFlight");
  assert.equal(record.steps[1].status, "complete");
  await assert.rejects(planManagement({ ...options, action: "update", packageDirectory }), /reconciliation_required/);
});

test("unconfirmed process termination retains the shared project lock", async t => {
  const { options } = await fixture(t);
  const result = await applyManagement(options, { runner: async (_, argv) => argv[1] === "install"
    ? { ok: false, terminationUnconfirmed: true } : { ok: true } });
  assert.equal(result.status, "attentionRequired");
  assert.equal(fs.existsSync(path.join(options.project, ".quotatempo-code-plugin-management", "operation.lock")), true);
  const record = JSON.parse(fs.readFileSync(path.join(options.receiptDirectory, "receipt.json"), "utf8"));
  assert.equal(record.terminationUnconfirmed, true);
});

test("loss of the canonical ledger cannot be bypassed using a fresh receipt", async t => {
  const { options, runner, root } = await fixture(t);
  await applyManagement(options, { runner });
  fs.unlinkSync(path.join(options.project, ".quotatempo-code-plugin-management", "state.json"));
  await assert.rejects(planManagement({ ...options, receiptDirectory: path.join(root, "new-receipt") }), /missing_project_ledger/);
});

test("receipt binding edits cannot change the canonical uninstall target", async t => {
  const { options, runner } = await fixture(t);
  await applyManagement(options, { runner });
  const file = path.join(options.receiptDirectory, "receipt.json"), record = JSON.parse(fs.readFileSync(file, "utf8"));
  record.pluginID = "quotatempo-usage-probe@quotatempo-code-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  fs.writeFileSync(file, JSON.stringify(record));
  await assert.rejects(planManagement({ ...options, action: "uninstall" }), /project_ledger_mismatch/);
});

test("version parsing waits for stdout ending after parent exit", async t => {
  const { options } = await fixture(t);
  const spawnProcess = () => {
    const child = new EventEmitter(); child.pid = 123; child.stdout = new PassThrough(); child.unref = () => {};
    queueMicrotask(() => { child.emit("exit", 0); child.stdout.end("2.1.289 (Claude Code)\n"); });
    return child;
  };
  assert.deepEqual(await runCommand(options.executable, ["--version"], options.project, {
    spawnProcess, killGroup: () => {} }), { ok: true });
});

test("post-exit group EPERM is not successful termination", async t => {
  const { options } = await fixture(t);
  const spawnProcess = () => {
    const child = new EventEmitter(); child.pid = 123; child.unref = () => {};
    queueMicrotask(() => child.emit("exit", 0)); return child;
  };
  assert.deepEqual(await runCommand(options.executable, ["plugin", "install"], options.project, {
    spawnProcess, killGroup: () => { throw Object.assign(new Error("denied"), { code: "EPERM" }); }
  }), { ok: false, terminationUnconfirmed: true });
});
