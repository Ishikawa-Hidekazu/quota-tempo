import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { runInNewContext } from "node:vm";
import { PLUGIN_FILES } from "../../../scripts/package-code-comparison-plugin.mjs";
import { fixtureModule, sandboxPolicy } from "./official-ipc-client.mjs";

// Source/guard tests only: no CLI, Swift, native listener, HTTP or model execution.
// percentUsed 42 is inline synthetic data, not an account/provider measurement.
const DIRECTORY = "/private/tmp/qtc-11111111-1111-4111-8111-111111111111";
const PUBLIC_KEY = "12".repeat(32);
const NOW = Date.parse("2026-10-06T00:00:00.000Z");
const REGISTER = "hooks/register.mjs";
const source = await readFile(new URL("../hooks/register.mjs", import.meta.url), "utf8");
const instrument = (text = source) => fixtureModule(text, DIRECTORY, NOW, PUBLIC_KEY);
const generated = instrument();

const commandStart = '  on("command.run", { command: COMMAND }, async ($, event, next) => {';
const measureStart = '  on("session.measure", async ($, event, next) => {';
const endStart = '  on("session.end", async ($, event, next) => {';
const registerStart = "export function register(on) {";
const commandRegistration = '    await $.command.register({ name: COMMAND, description: "Comparison-only QuotaTempo quota probe",';
const endAnchor = "    await stop($, state);\n    return next(event);\n  });\n}";

function between(text, start, end) {
  assert.equal(text.split(start).length, 2, "start must be unique");
  const begin = text.indexOf(start) + start.length;
  const finish = text.indexOf(end, begin);
  assert.ok(finish >= begin, "end must follow start");
  return text.slice(begin, finish);
}

// Execute only the extracted synthetic guard callbacks, never the plugin module.
function guard(event, matcher = "") {
  const start = `  on("${event}", ${matcher}`;
  assert.equal(generated.split(start).length, 2);
  const tail = generated.slice(generated.indexOf(start) + start.length);
  const line = tail.slice(0, tail.indexOf("\n"));
  let expression;
  if (line.endsWith(");")) expression = line.slice(0, -2);
  else {
    const finish = tail.indexOf("\n  });");
    assert.ok(finish > 0);
    expression = `${tail.slice(0, finish)}\n  }`;
  }
  return runInNewContext(`(${expression})`, Object.create(null), { timeout: 1000 });
}

const forbiddenAPI = new Proxy(Object.create(null), {
  get() { assert.fail("guard must not access any host API"); },
});

test("instrumentation is deterministic and leaves the production source string unchanged", () => {
  assert.equal(instrument(), generated);
  assert.notEqual(generated, source);
  assert.ok(!source.includes("qtc-native-fixture"));
});

test("imports and all original file-level helpers remain byte-identical", () => {
  assert.ok(generated.startsWith(source.slice(0, source.indexOf(registerStart))));
  assert.deepEqual(generated.match(/^import .*;$/gm), source.match(/^import .*;$/gm));
  assert.doesNotMatch(generated, /crypto-fixture|native-fixture\.mjs|claude-code\/testing/);
});

test("command and measurement handler bodies are preserved in file-level functions", () => {
  const commandBody = between(source, commandStart, `\n  });\n\n${measureStart}`);
  const measureBody = between(source, measureStart, `\n  });\n\n${endStart}`);
  assert.ok(generated.includes(`async function fixtureCommand($, event, next, state) {${commandBody}\n}`));
  assert.ok(generated.includes(`async function fixtureMeasure($, event, next, state) {${measureBody}\n}`));
  assert.ok(generated.includes('on("command.run", { command: COMMAND }, async ($, event, next) => fixtureCommand($, event, next, state));'));
  assert.ok(generated.includes('on("session.measure", async ($, event, next) => fixtureMeasure($, event, next, state));'));
  assert.ok(generated.indexOf("async function fixtureCommand(") < generated.indexOf(registerStart));
  assert.ok(generated.indexOf("async function fixtureMeasure(") < generated.indexOf(registerStart));
});

test("session hooks and shared state survive without duplicate session.start registration", () => {
  const state = between(source, registerStart, '\n  on("session.start",');
  assert.ok(generated.includes(`${registerStart}${state}`));
  assert.ok(generated.includes(endStart + between(source, endStart, "\n  });") + "\n  });"));
  for (const event of ["session.start", "session.measure", "session.end"]) {
    assert.equal(generated.split(`on("${event}",`).length - 1, 1);
  }
  assert.equal(generated.split('name: "qtc-native-fixture"').length - 1, 1);
  assert.match(generated, /name: "qtc-native-fixture", description: "Synthetic wire fixture", immediate: true/);
  assert.ok(generated.includes(commandRegistration));
});

test("all eight repo files stay unchanged; only the in-memory register copy is instrumented", async () => {
  assert.equal(PLUGIN_FILES.length, 8);
  const originals = new Map();
  for (const file of PLUGIN_FILES) {
    originals.set(file, await readFile(new URL(`../${file}`, import.meta.url)));
  }
  const copies = new Map([...originals].map(([name, bytes]) => [name, Buffer.from(bytes)]));
  copies.set(REGISTER, Buffer.from(instrument(copies.get(REGISTER).toString("utf8"))));
  assert.deepEqual([...copies.keys()], [...originals.keys()]);
  for (const [name, bytes] of originals) {
    assert.equal(copies.get(name).equals(bytes), name !== REGISTER, name);
    assert.ok((await readFile(new URL(`../${name}`, import.meta.url))).equals(bytes), name);
  }
  assert.equal([...copies].filter(([name, bytes]) => !bytes.equals(originals.get(name))).length, 1);
  assert.deepEqual(JSON.parse(copies.get("hooks/hooks.json")), { modules: ["./register.mjs"] });
});

for (const [name, anchor] of [
  ["command handler", commandStart], ["measurement handler", measureStart],
  ["register", registerStart],
  ["command registration", commandRegistration], ["closing session end", endAnchor],
]) {
  for (const change of ["missing", "duplicate"]) {
    test(`instrumentation rejects ${change} ${name} anchor`, () => {
      const changed = change === "missing" ? source.replace(anchor, "") : `${source}\n${anchor}`;
      assert.throws(() => instrument(changed), /^Error: instrumentationMismatch$/);
    });
  }
}

test("instrumentation rejects a missing session.end boundary", () => {
  assert.throws(() => instrument(source.replace(endStart, "")), /instrumentationMismatch/);
});

test("session.end marker uniqueness remains an official validator check, not a source parser claim", () => {
  // This marker is only an extraction boundary, not a unique replacement anchor.
  // Keep the current limitation explicit; these tests do not run the validator.
  const extra = `${endStart}\n    return next(event);\n  });`;
  const changed = `${source}\n${extra}`;
  const result = instrument(changed);
  assert.ok(result.endsWith(extra));
  assert.equal(result.split('on("session.end",').length - 1, 2);
});

test("unsupported line-ending drift and already-instrumented input fail closed", () => {
  assert.throws(() => instrument(source.replaceAll("\n", "\r\n")), /instrumentationMismatch/);
  assert.throws(() => instrument(generated), /instrumentationMismatch/);
});

test("synthetic percent 42 and reset +24h coexist with the original real clock calls", () => {
  assert.ok(generated.includes(`args: ${JSON.stringify(`connect ${DIRECTORY} ${PUBLIC_KEY}`)}`));
  assert.match(generated, /kind: "seven_day", percentUsed: 42/);
  assert.ok(generated.includes(`resetsAt: ${JSON.stringify(new Date(NOW + 86400000).toISOString())}`));
  assert.match(generated, /await \$\.clock\.now\(\)/);
  assert.match(generated, /await \$\.clock\.sleep\(3000\)/);
  assert.doesNotMatch(generated, /\$\.session\.usage\s*\(|\$\s*=|\$\.http\.fetch\s*=/);
  assert.match(generated, /finally \{[\s\S]*args: "disconnect"[\s\S]*disconnected = result\?\.text === "QuotaTempo probe disconnected\. No product source was changed\."/);
  assert.match(generated, /validated && disconnected \? "fixtureValidated" : "fixtureDisconnectFailed"/);
});

test("prompt guard permits only the three exact control/fixture commands", async () => {
  const callback = guard("prompt.submit");
  for (const text of ["/qtc-native-fixture", "/qtc-native-fixture status", "/quotatempo-probe status"]) {
    const event = { text: ` ${text} ` };
    let calls = 0;
    const result = await callback(forbiddenAPI, event, async value => { calls++; return value; });
    assert.equal(result, event);
    assert.equal(calls, 1);
  }
  for (const text of ["", "write a story", "/unknown", "/qtc-native-fixture extra",
    "/qtc-native-fixture status extra", "/quotatempo-probe connect", "/qtc-native-fixture\n/model"]) {
    const result = await callback(forbiddenAPI, { text }, () => assert.fail("must not continue"));
    assert.equal(result.drop, "fixtureUnsupported");
    assert.deepEqual(Object.keys(result), ["drop"]);
  }
});

test("turn guard rejects without consulting host APIs or invoking next", async () => {
  await assert.rejects(guard("turn.start")(forbiddenAPI, {}, () => assert.fail("must not continue")),
    /^Error: fixtureModelForbidden$/);
});

test("fixture status and unsupported arguments return before any host or native operation", async () => {
  const callback = guard("command.run", '{ command: "qtc-native-fixture" }, ');
  const next = () => assert.fail("must not invoke the engine continuation");
  const prepared = await callback(forbiddenAPI, { args: "status" }, next);
  assert.equal(prepared.text, "fixturePrepared");
  for (const args of ["extra", "status extra", "connect /synthetic", " status "]) {
    const result = await callback(forbiddenAPI, { args }, next);
    assert.equal(result.text, "fixtureUnsupported");
  }
});

for (const event of ["model.complete", "model.fork", "model.classify"]) {
  test(`synthetic ${event} interception denies without making a model request`, async () => {
    const result = await guard(event)(forbiddenAPI, {}, () => assert.fail("must not continue"));
    assert.equal(result.deny, "fixtureModelForbidden");
    assert.deepEqual(Object.keys(result), ["deny"]);
  });
}

test("sandbox policy has one exact Unix allowance and explicit TCP/UDP and normal HOME denial", () => {
  const home = "/Users/synthetic-normal-home";
  const socket = `${DIRECTORY}/bridge.sock`;
  const policy = sandboxPolicy(home, socket);
  // allow default is not full filesystem confinement; network/home exceptions
  // are constrained here. These source tests do not prove OS policy enforcement.
  assert.equal(policy, `(version 1) (allow default)
    (deny network*)
    (allow network-outbound (literal ${JSON.stringify(socket)}))
    (deny network-outbound (remote tcp) (remote udp))
    (deny file-read* file-write* (subpath ${JSON.stringify(home)}))`);
  assert.equal(policy.match(/\(allow network[^)]*/g).length, 1);
  assert.doesNotMatch(policy, /\(allow network-outbound \((?:subpath|remote|local)|\(allow (?:file-read|file-write|network\*)/);
  assert.doesNotMatch(policy, /\(allow network-(?:inbound|bind)/);
  const other = sandboxPolicy(home, "/private/tmp/synthetic-other/bridge.sock");
  assert.ok(!other.includes(socket));
  assert.equal(other.replace(JSON.stringify("/private/tmp/synthetic-other/bridge.sock"), JSON.stringify(socket)), policy);
});

test("sandbox literals quote synthetic punctuation and policy-looking text as data", () => {
  const home = '/Users/synthetic "quoted"\n(allow network*)';
  const socket = '/private/tmp/synthetic\\socket"\n(allow network*)';
  const policy = sandboxPolicy(home, socket);
  assert.ok(policy.includes(`(literal ${JSON.stringify(socket)})`));
  assert.ok(policy.includes(`(subpath ${JSON.stringify(home)})`));
  assert.equal(policy.split("\n").length, 5);
  assert.ok(!policy.includes(home));
  assert.ok(!policy.includes(socket));
});
