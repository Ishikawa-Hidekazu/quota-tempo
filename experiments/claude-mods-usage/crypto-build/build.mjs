import { build } from "esbuild-wasm";
import fs from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const root = fileURLToPath(new URL(".", import.meta.url));
const check = process.argv.slice(2).join(" ") === "--check";
if (process.argv.length > 2 && !check) throw new Error("invalid_arguments");
async function emit(output, bytes) {
  const target = join(root, output);
  if (check) {
    const existing = await fs.readFile(target);
    if (!existing.equals(Buffer.from(bytes))) throw new Error(`generated_bundle_drift: ${output}`);
  } else { await fs.writeFile(target, bytes); }
}
const notice = [];
for (const name of ["hpke", "@panva/hpke-noble", "@noble/curves", "@noble/ciphers", "@noble/hashes"]) {
  const directory = join(root, "node_modules", name);
  const metadata = JSON.parse(await fs.readFile(join(directory, "package.json"), "utf8"));
  const license = await fs.readFile(join(directory, name.startsWith("@noble/") ? "LICENSE" : "LICENSE.md"), "utf8");
  notice.push(`${name} ${metadata.version}\n${license}`);
}
const outputs = [
  ["entry.mjs", "../transport-crypto.mjs"],
  ["fixture-entry.mjs", "../tests/crypto-fixture.mjs"],
];
for (const [entry, output] of outputs) {
  const result = await build({ absWorkingDir: root, entryPoints: [entry], bundle: true,
    platform: "browser", format: "esm", target: "es2022", minify: true, write: false,
    legalComments: "inline", metafile: true, treeShaking: true });
  if (Object.values(result.metafile.outputs).some(o => o.imports.length)) throw new Error("external_runtime_import");
  const bytes = result.outputFiles[0].contents;
  const text = new TextDecoder().decode(bytes);
  if (/\b(?:fetch|XMLHttpRequest|WebSocket|require)\s*\(|node:|\bprocess\./.test(text)) throw new Error("unexpected_runtime_access");
  await emit(output, bytes);
  console.log(JSON.stringify({ output, bytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") }));
}
await emit("../THIRD_PARTY_NOTICES.txt", Buffer.from(notice.join("\n\n")));
