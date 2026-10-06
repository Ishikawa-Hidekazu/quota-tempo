// Synthetic server for tests only; this file and its bundle are never packaged.
import { CipherSuite } from "hpke";
import { KEM_DHKEM_X25519_HKDF_SHA256, KDF_HKDF_SHA256, AEAD_ChaCha20Poly1305 } from "@panva/hpke-noble";
import { x25519 } from "@noble/curves/ed25519.js";
import { hmac } from "@noble/hashes/hmac.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils.js";
const suite = new CipherSuite(KEM_DHKEM_X25519_HKDF_SHA256, KDF_HKDF_SHA256, AEAD_ChaCha20Poly1305);
const encoder = new TextEncoder();
const seed = new Uint8Array(32).fill(7);
export const TEST_PUBLIC_KEY = bytesToHex(x25519.getPublicKey(seed));
export async function openRequest(envelope, endpoint) {
  const info = `QuotaTempo.CodeComparison.v3|${envelope.connectionID}|${envelope.streamID}|${envelope.requestID}|${endpoint}`;
  const privateKey = await suite.DeserializePrivateKey(seed, false);
  const ctx = await suite.SetupRecipient(privateKey, hexToBytes(envelope.enc), { info: encoder.encode(info) });
  const bytes = await ctx.Open(hexToBytes(envelope.ciphertext));
  const key = await ctx.Export(encoder.encode("QuotaTempo.CodeComparison.response.v3"), 32);
  return {
    body: JSON.parse(new TextDecoder().decode(bytes)),
    reply(status) {
      return { schemaVersion: 3, status, requestID: envelope.requestID,
        proof: bytesToHex(hmac(sha256, key, encoder.encode(`${info}|${status}`))) };
    },
  };
}
