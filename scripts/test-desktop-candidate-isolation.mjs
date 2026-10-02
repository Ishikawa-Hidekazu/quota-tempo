#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const candidate = "QuotaTempoDesktopCandidate";
const testTarget = `${candidate}Tests`;
const previewEnvironment = "QUOTATEMPO_DESKTOP_INTEGRATION_PREVIEW";
const previewDefine = "DESKTOP_INTEGRATION_PREVIEW";
const app = "QuotaTempoApp";
const appTests = "QuotaTempoAppTests";
const previewTargets = [app, appTests];
const isolatedTargets = [
  "QuotaTempoBridge", "QuotaTempoBrowserHost", "QuotaTempoCore", "QuotaTempoFixtureRenderer",
];
const candidateDependency = { target: [candidate, null] };
const previewSetting = { kind: { define: { _0: previewDefine } }, tool: "swift" };

function dumpManifest(value) {
  const env = { ...process.env };
  // Always inspect the default graph even when this validator is run in preview mode.
  delete env[previewEnvironment];
  if (value !== undefined) env[previewEnvironment] = value;
  return JSON.parse(execFileSync("swift", ["package", "dump-package"], {
    cwd: root,
    env,
    encoding: "utf8",
    timeout: 30_000,
    maxBuffer: 1_048_576,
  }));
}

function dependencyName(dependency) {
  return (dependency.byName ?? dependency.target)?.[0];
}

function dependencies(target) {
  return target.dependencies.map(dependencyName).filter(Boolean);
}

function previewSettings(target) {
  return target.settings.filter((setting) => setting.kind.define?._0 === previewDefine);
}

function validate(input, preview) {
  const targets = new Map(input.targets.map((target) => [target.name, target]));
  assert.equal(targets.size, input.targets.length, "Target names must be unique");
  assert.equal(targets.get(candidate)?.type, "regular");
  assert.equal(targets.get(testTarget)?.type, "test");
  assert.equal(targets.get(app)?.type, "executable");
  assert.equal(targets.get(appTests)?.type, "test");
  assert.deepEqual(input.products.find((product) => product.name === "QuotaTempo")?.targets, [app]);

  function reachesCandidate(roots) {
    const pending = [...roots];
    const visited = new Set();
    while (pending.length) {
      const name = pending.pop();
      if (name === candidate) return true;
      if (visited.has(name)) continue;
      visited.add(name);
      const target = targets.get(name);
      if (target) pending.push(...dependencies(target));
    }
    return false;
  }

  for (const name of isolatedTargets) {
    assert(targets.has(name), `Missing isolated target: ${name}`);
    assert.equal(reachesCandidate([name]), false, `${name} must never reach the desktop candidate`);
  }
  for (const product of input.products) {
    assert.equal(reachesCandidate(product.targets), preview && product.name === "QuotaTempo",
      `Desktop candidate product graph violation: ${product.name}`);
  }
  for (const target of input.targets) {
    const candidateReferences = target.dependencies.filter((dependency) => dependencyName(dependency) === candidate);
    const expectedCount = target.name === testTarget || (preview && previewTargets.includes(target.name)) ? 1 : 0;
    assert.equal(candidateReferences.length, expectedCount,
      `Unexpected candidate dependency on ${target.name}`);
    if (preview && previewTargets.includes(target.name)) {
      assert.deepEqual(candidateReferences, [candidateDependency], "Preview dependency must be exact and unconditional");
    }
    const expectedSettings = preview && previewTargets.includes(target.name) ? [previewSetting] : [];
    assert.deepEqual(previewSettings(target), expectedSettings,
      `Preview define must be exact and limited to App/AppTests: ${target.name}`);
  }
}

function validatePair(defaultManifest, previewManifest) {
  validate(defaultManifest, false);
  validate(previewManifest, true);
  const expected = structuredClone(defaultManifest);
  for (const name of previewTargets) {
    expected.targets.find((target) => target.name === name).dependencies.push(candidateDependency);
    expected.targets.find((target) => target.name === name).settings.push(previewSetting);
  }
  assert.deepEqual(previewManifest, expected,
    "Preview may change only App/AppTests candidate dependencies and defines");
}

const inheritedPreview = process.env[previewEnvironment];
const defaultManifest = dumpManifest();
const previewManifest = dumpManifest("1");
validatePair(defaultManifest, previewManifest);

const arbitraryValues = ["", "0", "true", "yes", "01", "1 ", "arbitrary"];
for (const value of arbitraryValues) {
  const manifest = dumpManifest(value);
  validate(manifest, false);
  assert.deepEqual(manifest, defaultManifest, `Only the exact preview value 1 may enable integration: ${JSON.stringify(value)}`);
}
assert(process.env[previewEnvironment] === inheritedPreview, "Manifest checks must not mutate the caller environment");

let regressionCount = 0;
function rejects(preview, mutate, message) {
  const manifest = structuredClone(preview ? previewManifest : defaultManifest);
  mutate(manifest);
  assert.throws(() => validate(manifest, preview), { code: "ERR_ASSERTION" }, message);
  regressionCount += 1;
}

function target(input, name) {
  return input.targets.find((item) => item.name === name);
}

for (const preview of [false, true]) {
  for (const name of preview ? isolatedTargets : [...previewTargets, ...isolatedTargets]) {
    for (const reference of ["byName", "target"]) {
      rejects(preview, (input) => target(input, name).dependencies.push({ [reference]: [candidate, null] }),
        `${name} direct leak (${reference}, preview=${preview})`);
    }
  }
  for (const name of [candidate, testTarget, ...(preview ? previewTargets : [])]) {
    rejects(preview, (input) => input.products.push({ name: "AccidentalExport", targets: [name] }),
      `Accidental product export through ${name}`);
  }
  rejects(preview, (input) => {
    input.targets.push({ name: "LeakedHelper", type: "regular", settings: [], dependencies: [{ byName: [candidate, null] }] });
    target(input, "QuotaTempoBridge").dependencies.push({ target: ["LeakedHelper", null] });
  }, "Transitive helper leak");
  rejects(preview, (input) => target(input, testTarget).dependencies = [], "Candidate tests must retain their dependency");
  rejects(preview, (input) => target(input, "QuotaTempoCore").settings.push(previewSetting), "Define leaks into Core");
}

for (const name of previewTargets) {
  rejects(false, (input) => target(input, name).settings.push(previewSetting), "Missing default define guard");
  rejects(true, (input) => target(input, name).settings = [], `Missing preview define on ${name}`);
  rejects(true, (input) => target(input, name).settings.push(previewSetting), "Duplicate preview define");
  rejects(true, (input) => previewSettings(target(input, name))[0].condition = { config: "debug" },
    "Preview define must not be restricted to debug builds");
  rejects(true, (input) => {
    target(input, name).dependencies = target(input, name).dependencies.filter((dependency) => dependencyName(dependency) !== candidate);
  }, `Missing preview dependency on ${name}`);
  rejects(true, (input) => target(input, name).dependencies.push(candidateDependency), `Duplicate preview dependency on ${name}`);
  rejects(true, (input) => {
    target(input, name).dependencies.find((dependency) => dependencyName(dependency) === candidate).target[1] = { platformNames: ["macos"] };
  }, `Preview dependency must not have an extra condition on ${name}`);
}
for (const name of isolatedTargets) {
  for (const previewTarget of previewTargets) {
    rejects(true, (input) => target(input, name).dependencies.push({ byName: [previewTarget, null] }),
      `${name} must not reach candidate indirectly through ${previewTarget}`);
  }
}
const drifted = structuredClone(previewManifest);
target(drifted, app).dependencies.push({ product: ["Unexpected", "Unexpected", null, null] });
assert.throws(() => validatePair(defaultManifest, drifted), /Preview may change only/);
regressionCount += 1;
for (const missing of [defaultManifest, previewManifest]) {
  assert.throws(() => validatePair(missing, missing), { code: "ERR_ASSERTION" }, "Missing environment guard");
  regressionCount += 1;
}
console.log(`desktop_candidate_product_isolation=PASS (default + preview, ${arbitraryValues.length} non-opt-in values, ${regressionCount} regression fixtures)`);
