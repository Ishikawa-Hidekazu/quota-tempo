#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const candidate = "QuotaTempoDesktopCandidate";
const testTarget = `${candidate}Tests`;
const previewEnvironment = "QUOTATEMPO_DESKTOP_INTEGRATION_PREVIEW";
const featureDefine = "DESKTOP_CONNECTION";
const previewDefine = "DESKTOP_INTEGRATION_PREVIEW";
const app = "QuotaTempoApp";
const appTests = "QuotaTempoAppTests";
const featureTargets = [app, appTests];
const isolatedTargets = [
  "QuotaTempoBridge", "QuotaTempoBrowserHost", "QuotaTempoCore", "QuotaTempoFixtureRenderer",
];
const candidateDependency = { target: [candidate, null] };
const candidateTestDependency = { byName: [candidate, null] };
const featureSetting = { kind: { define: { _0: featureDefine } }, tool: "swift" };
const previewSetting = { kind: { define: { _0: previewDefine } }, tool: "swift" };
const normalExcludes = {
  [candidate]: [
    "DesktopPreviewModel.swift", "DesktopPreviewMenu.swift",
    "DesktopPreviewInstanceLock.swift", "DesktopPreviewTermination.swift",
  ],
  [testTarget]: [
    "DesktopPreviewModelTests.swift", "DesktopPreviewMenuTests.swift",
    "DesktopPreviewInstanceLockTests.swift", "DesktopPreviewTerminationTests.swift",
  ],
};
const publicProducts = [
  { name: "QuotaTempoCore", targets: ["QuotaTempoCore"], type: { library: ["automatic"] } },
  { name: "QuotaTempo", targets: [app], type: { executable: null } },
  ...["QuotaTempoFixtureRenderer", "QuotaTempoBridge", "QuotaTempoBrowserHost"].map((name) => ({
    name, targets: [name], type: { executable: null },
  })),
];

function dumpManifest(value) {
  const env = { ...process.env };
  // Always inspect the normal graph even when this validator is run in preview mode.
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

function defineSettings(target, define) {
  return target.settings.filter((setting) => setting.kind.define?._0 === define);
}

function target(input, name) {
  return input.targets.find((item) => item.name === name);
}

function validate(input, preview) {
  const targets = new Map(input.targets.map((item) => [item.name, item]));
  assert.equal(targets.size, input.targets.length, "Target names must be unique");
  assert.equal(targets.get(candidate)?.type, "regular");
  assert.equal(targets.get(testTarget)?.type, "test");
  assert.equal(targets.get(app)?.type, "executable");
  assert.equal(targets.get(appTests)?.type, "test");
  assert.deepEqual(input.products.map(({ name, targets, type }) => ({ name, targets, type })),
    publicProducts, "Public product exports must remain unchanged");
  for (const [name, excludes] of Object.entries(normalExcludes)) {
    assert.deepEqual(targets.get(name).exclude, preview ? [] : excludes,
      `Local helper excludes must be exact (${preview ? "preview" : "normal"}): ${name}`);
  }

  function reachesCandidate(roots) {
    const pending = [...roots];
    const visited = new Set();
    while (pending.length) {
      const name = pending.pop();
      if (name === candidate) return true;
      if (visited.has(name)) continue;
      visited.add(name);
      const item = targets.get(name);
      assert(item, `Unknown local target: ${name}`);
      pending.push(...dependencies(item));
    }
    return false;
  }

  for (const name of isolatedTargets) {
    assert(targets.has(name), `Missing isolated target: ${name}`);
    assert.equal(reachesCandidate([name]), false, `${name} must never reach the desktop candidate`);
  }
  for (const product of input.products) {
    assert.equal(reachesCandidate(product.targets), product.name === "QuotaTempo",
      `Desktop candidate product graph violation: ${product.name}`);
  }
  for (const item of input.targets) {
    const isFeatureTarget = featureTargets.includes(item.name);
    const references = item.dependencies.filter((dependency) => dependencyName(dependency) === candidate);
    const expectedReferences = isFeatureTarget ? [candidateDependency]
      : item.name === testTarget ? [candidateTestDependency] : [];
    assert.deepEqual(references, expectedReferences,
      `Candidate dependency must be exact and unconditional: ${item.name}`);
    if (![candidate, testTarget, ...featureTargets].includes(item.name)) {
      assert.equal(reachesCandidate([item.name]), false,
        `${item.name} must never reach the desktop candidate`);
    }
    assert.deepEqual(defineSettings(item, featureDefine), isFeatureTarget ? [featureSetting] : [],
      `Feature define must be exact, unconditional and limited to App/AppTests: ${item.name}`);
    assert.deepEqual(defineSettings(item, previewDefine), preview && isFeatureTarget ? [previewSetting] : [],
      `Preview define must be exact and limited to App/AppTests: ${item.name}`);
  }
}

function validatePair(defaultManifest, previewManifest) {
  validate(defaultManifest, false);
  validate(previewManifest, true);
  const expected = structuredClone(defaultManifest);
  for (const name of featureTargets) target(expected, name).settings.push(previewSetting);
  for (const name of Object.keys(normalExcludes)) target(expected, name).exclude = [];
  assert.deepEqual(previewManifest, expected,
    "Preview may change only App/AppTests preview defines and Candidate/CandidateTests helper excludes");
}

function validateNonPreview(defaultManifest, manifest, value) {
  validate(manifest, false);
  assert.deepEqual(manifest, defaultManifest,
    `Only the exact preview value 1 may enable preview: ${JSON.stringify(value)}`);
}

// This mode exercises the validator, not Package.swift. Normal invocations still
// require real dump-package output for every environment value and cannot skip it.
function syntheticManifest() {
  function item(name, type, names, settings = []) {
    return { name, type, dependencies: names.map((name) => ({ byName: [name, null] })), settings: structuredClone(settings) };
  }
  const manifest = {
    products: structuredClone(publicProducts),
    targets: [
      item("QuotaTempoCore", "regular", []),
      item(candidate, "regular", ["QuotaTempoCore"]),
      item(app, "executable", ["QuotaTempoCore"], [featureSetting]),
      ...isolatedTargets.filter((name) => name !== "QuotaTempoCore")
        .map((name) => item(name, "executable", ["QuotaTempoCore"])),
      item("QuotaTempoCoreTests", "test", ["QuotaTempoCore"]),
      item(appTests, "test", [app, "QuotaTempoCore"], [featureSetting]),
      item(testTarget, "test", [candidate, "QuotaTempoCore"]),
    ],
  };
  for (const name of featureTargets) target(manifest, name).dependencies.push(structuredClone(candidateDependency));
  for (const [name, excludes] of Object.entries(normalExcludes)) target(manifest, name).exclude = [...excludes];
  target(manifest, app).dependencies.push({ product: ["Sparkle", "Sparkle", null, null] });
  return structuredClone(manifest);
}

const args = process.argv.slice(2);
assert(args.length === 0 || (args.length === 1 && args[0] === "--synthetic-only"),
  "Usage: test-desktop-candidate-isolation.mjs [--synthetic-only]");
const syntheticOnly = args.length === 1;
const inheritedPreview = process.env[previewEnvironment];
const defaultManifest = syntheticOnly ? syntheticManifest() : dumpManifest();
const previewManifest = syntheticOnly ? structuredClone(defaultManifest) : dumpManifest("1");
if (syntheticOnly) {
  for (const name of featureTargets) target(previewManifest, name).settings.push(structuredClone(previewSetting));
  for (const name of Object.keys(normalExcludes)) target(previewManifest, name).exclude = [];
}
validatePair(defaultManifest, previewManifest);

const arbitraryValues = ["", "0", "true", "yes", "01", "1 ", " 1", "1\n", "-1", "arbitrary"];
if (!syntheticOnly) {
  for (const value of arbitraryValues) validateNonPreview(defaultManifest, dumpManifest(value), value);
}
assert(process.env[previewEnvironment] === inheritedPreview, "Manifest checks must not mutate the caller environment");

let regressionCount = 0;
let positiveCount = 1;
function rejects(preview, mutate, message) {
  const manifest = structuredClone(preview ? previewManifest : defaultManifest);
  mutate(manifest);
  assert.throws(() => validate(manifest, preview), { code: "ERR_ASSERTION" }, message);
  regressionCount += 1;
}

for (const preview of [false, true]) {
  for (const [name, excludes] of Object.entries(normalExcludes)) {
    rejects(preview, (input) => delete target(input, name).exclude, `Missing exclude list on ${name}`);
    rejects(preview, (input) => target(input, name).exclude = null, `Invalid exclude list on ${name}`);
    rejects(preview, (input) => target(input, name).exclude = preview ? [...excludes] : [],
      `Wrong configuration excludes on ${name}`);
    for (const file of excludes) {
      if (preview) {
        rejects(true, (input) => target(input, name).exclude.push(file), `Preview must retain ${file}`);
      } else {
        rejects(false, (input) => target(input, name).exclude = excludes.filter((item) => item !== file),
          `Normal must exclude ${file}`);
        rejects(false, (input) => target(input, name).exclude.push(file), `Duplicate exclude ${file}`);
        rejects(false, (input) => target(input, name).exclude = excludes.map((item) => item === file ? `Wrong${file}` : item),
          `Wrong helper filename ${file}`);
      }
    }
    const sharedFiles = name === candidate
      ? ["DesktopPreviewServing.swift", "DesktopPreviewPresentation.swift", "DesktopConnectionController.swift"]
      : ["DesktopPreviewPresentationTests.swift", "DesktopConnectionControllerTests.swift"];
    for (const file of sharedFiles) {
      rejects(preview, (input) => target(input, name).exclude.push(file), `Shared code must remain included: ${file}`);
    }
  }

  // Safe helpers remain legal; they cannot add another route into the candidate.
  const safe = structuredClone(preview ? previewManifest : defaultManifest);
  safe.targets.push({ name: "SafeHelper", type: "regular", settings: [], dependencies: [{ byName: ["QuotaTempoCore", null] }] });
  target(safe, "QuotaTempoBridge").dependencies.push({ target: ["SafeHelper", null] });
  validate(safe, preview);
  positiveCount += 1;

  for (const name of [...isolatedTargets, "QuotaTempoCoreTests"]) {
    for (const reference of ["byName", "target"]) {
      rejects(preview, (input) => target(input, name).dependencies.push({ [reference]: [candidate, null] }),
        `${name} direct leak (${reference}, preview=${preview})`);
    }
    for (const via of [...featureTargets, testTarget]) {
      rejects(preview, (input) => target(input, name).dependencies.push({ target: [via, null] }),
        `${name} must not reach candidate indirectly through ${via}`);
    }
    rejects(preview, (input) => {
      input.targets.push({ name: "LeakedHelper", type: "regular", settings: [], dependencies: [{ byName: [candidate, null] }] });
      target(input, name).dependencies.push({ target: ["LeakedHelper", null] });
    }, `${name} transitive helper leak`);
  }
  for (const name of [candidate, testTarget, ...featureTargets, "QuotaTempoCore"]) {
    rejects(preview, (input) => input.products.push({ name: "AccidentalExport", targets: [name], type: { executable: null } }),
      `Accidental product export through ${name}`);
  }
  rejects(preview, (input) => input.products.push(structuredClone(input.products[1])), "Duplicate public export");
  rejects(preview, (input) => input.products[0].type = { executable: null }, "Library must not become an executable export");
  rejects(preview, (input) => input.products[1].targets.push(candidate), "Extra target in the main product");
  rejects(preview, (input) => input.products.pop(), "Missing public product");
  rejects(preview, (input) => input.targets.push(structuredClone(target(input, app))), "Duplicate target");
  rejects(preview, (input) => input.targets = input.targets.filter((item) => item.name !== candidate), "Missing candidate target");
  rejects(preview, (input) => target(input, candidate).type = "executable", "Candidate must not be executable");
  rejects(preview, (input) => {
    input.targets.push({ name: "HiddenHelper", type: "regular", settings: [], dependencies: [{ target: [app, null] }] });
  }, "Even an unexported helper must not acquire the feature indirectly");

  for (const name of [...featureTargets, testTarget]) {
    rejects(preview, (input) => {
      target(input, name).dependencies = target(input, name).dependencies.filter((dependency) => dependencyName(dependency) !== candidate);
    }, `Missing candidate dependency on ${name}`);
    rejects(preview, (input) => target(input, name).dependencies.push(candidateDependency), `Duplicate candidate dependency on ${name}`);
    rejects(preview, (input) => {
      const dependency = target(input, name).dependencies.find((item) => dependencyName(item) === candidate);
      (dependency.target ?? dependency.byName)[1] = { platformNames: ["macos"] };
    }, `Conditional candidate dependency on ${name}`);
  }

  for (const name of featureTargets) {
    for (const define of [featureDefine, ...(preview ? [previewDefine] : [])]) {
      rejects(preview, (input) => {
        target(input, name).settings = target(input, name).settings.filter((setting) => setting.kind.define?._0 !== define);
      }, `Missing ${define} on ${name}`);
      rejects(preview, (input) => target(input, name).settings.push(structuredClone(define === featureDefine ? featureSetting : previewSetting)),
        `Duplicate ${define} on ${name}`);
      for (const condition of [{ config: "debug" }, { platformNames: ["macos"] }]) {
        rejects(preview, (input) => defineSettings(target(input, name), define)[0].condition = condition,
          `Conditional ${define} on ${name}`);
      }
      rejects(preview, (input) => defineSettings(target(input, name), define)[0].tool = "c",
        `${define} must be a Swift define on ${name}`);
    }
    if (!preview) rejects(false, (input) => target(input, name).settings.push(previewSetting), `Preview define in normal ${name}`);
  }
  for (const name of [candidate, testTarget, ...isolatedTargets, "QuotaTempoCoreTests"]) {
    for (const setting of [featureSetting, previewSetting]) {
      rejects(preview, (input) => target(input, name).settings.push(setting), `Define leak into ${name}`);
    }
  }
}

for (const [message, mutate] of [
  ["dependency", (input) => target(input, app).dependencies.push({ product: ["Unexpected", "Unexpected", null, null] })],
  ["unrelated define", (input) => target(input, app).settings.push({ kind: { define: { _0: "UNRELATED" } }, tool: "swift" })],
  ["unrelated exclude", (input) => target(input, app).exclude = ["QuotaTempoApp.swift"]],
  ["target", (input) => input.targets.push({ name: "PreviewOnlyHelper", type: "regular", settings: [], dependencies: [] })],
]) {
  const drifted = structuredClone(previewManifest);
  mutate(drifted);
  assert.throws(() => validatePair(defaultManifest, drifted), /Preview may change only/, `Preview ${message} drift`);
  regressionCount += 1;
}
for (const missing of [defaultManifest, previewManifest]) {
  assert.throws(() => validatePair(missing, missing), { code: "ERR_ASSERTION" }, "Missing environment guard");
  regressionCount += 1;
}
for (const value of arbitraryValues) {
  validateNonPreview(defaultManifest, structuredClone(defaultManifest), value);
  positiveCount += 1;
  assert.throws(() => validateNonPreview(defaultManifest, previewManifest, value), { code: "ERR_ASSERTION" },
    `Non-exact value ${JSON.stringify(value)} must not enable preview`);
  regressionCount += 1;
}
console.log(`${syntheticOnly ? "desktop_candidate_graph_fixtures" : "desktop_candidate_product_isolation"}=PASS `
  + `(${syntheticOnly ? "synthetic only; manifest not verified" : `normal + preview, ${arbitraryValues.length} non-opt-in values`}, `
  + `${positiveCount} positive, ${regressionCount} negative regression fixtures)`);
