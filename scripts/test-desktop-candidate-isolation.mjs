#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const candidate = "QuotaTempoDesktopCandidate";
const testTarget = `${candidate}Tests`;
const manifest = JSON.parse(execFileSync("swift", ["package", "dump-package"], {
  cwd: root,
  encoding: "utf8",
  timeout: 30_000,
  maxBuffer: 1_048_576,
}));

function dependencies(target) {
  return target.dependencies.flatMap((dependency) => {
    const reference = dependency.byName ?? dependency.target;
    return reference ? [reference[0]] : [];
  });
}

function validate(input) {
  const targets = new Map(input.targets.map((target) => [target.name, target]));
  assert.equal(targets.get(candidate)?.type, "regular");
  assert.equal(targets.get(testTarget)?.type, "test");
  assert(dependencies(targets.get(testTarget)).includes(candidate));

  for (const product of input.products) {
    const pending = [...product.targets];
    const visited = new Set();
    while (pending.length) {
      const name = pending.pop();
      assert.notEqual(name, candidate, "Desktop candidate must not enter a shipped product graph");
      if (visited.has(name)) continue;
      visited.add(name);
      const target = targets.get(name);
      if (target) pending.push(...dependencies(target));
    }
  }
}

validate(manifest);
for (const targetName of ["QuotaTempoApp", "QuotaTempoCore", "QuotaTempoBrowserHost"]) {
  const leaked = structuredClone(manifest);
  leaked.targets.find((target) => target.name === targetName)
    .dependencies.push({ byName: [candidate, null] });
  assert.throws(() => validate(leaked), /must not enter a shipped product graph/);
}
const exported = structuredClone(manifest);
exported.products.push({ name: "AccidentalExport", targets: [candidate] });
assert.throws(() => validate(exported), /must not enter a shipped product graph/);
console.log("desktop_candidate_product_isolation=PASS (manifest and four leak fixtures)");
