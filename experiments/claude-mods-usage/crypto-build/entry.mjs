import { CipherSuite } from "hpke";
import { KEM_DHKEM_X25519_HKDF_SHA256, KDF_HKDF_SHA256, AEAD_ChaCha20Poly1305 } from "@panva/hpke-noble";
import { hmac } from "@noble/hashes/hmac.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils.js";
import { equalBytes } from "@noble/ciphers/utils.js";

const suite = new CipherSuite(KEM_DHKEM_X25519_HKDF_SHA256, KDF_HKDF_SHA256, AEAD_ChaCha20Poly1305);
const encoder = new TextEncoder();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const EXPORT_CONTEXT = encoder.encode("QuotaTempo.CodeComparison.response.v3");

export async function sealRequest(publicKey, connectionID, streamID, endpoint, plaintext) {
  if (typeof publicKey !== "string" || !/^[0-9a-f]{64}$/.test(publicKey)
    || !UUID.test(connectionID) || !UUID.test(streamID)
    || !["connect", "measure", "disconnect"].includes(endpoint)
    || typeof plaintext !== "string") throw new Error("invalid_binding");
  const bytes = encoder.encode(plaintext);
  if (!bytes.length || bytes.length > 4096) throw new Error("invalid_payload");
  const requestID = crypto.randomUUID();
  if (!UUID.test(requestID)) throw new Error("invalid_randomness");
  const info = `QuotaTempo.CodeComparison.v3|${connectionID}|${streamID}|${requestID}|${endpoint}`;
  const key = await suite.DeserializePublicKey(hexToBytes(publicKey));
  const { encapsulatedSecret, ctx } = await suite.SetupSender(key, { info: encoder.encode(info) });
  const ciphertext = await ctx.Seal(bytes);
  // Only ciphertext is exposed to the HTTP adapter. The response key stays in
  // this single-use closure and is erased whether verification succeeds or fails.
  const proofKey = await ctx.Export(EXPORT_CONTEXT, 32);
  const body = JSON.stringify({ schemaVersion: 3, connectionID, streamID, requestID,
    enc: bytesToHex(encapsulatedSecret), ciphertext: bytesToHex(ciphertext) });
  let used = false;
  return {
    body,
    verify(reply, status) {
      if (used) throw new Error("response_already_checked");
      used = true;
      try {
        if (!reply || Array.isArray(reply) || Object.keys(reply).length !== 4
          || !["schemaVersion", "status", "requestID", "proof"].every(k => Object.hasOwn(reply, k))
          || reply.schemaVersion !== 3 || reply.status !== status || reply.requestID !== requestID
          || typeof reply.proof !== "string" || !/^[0-9a-f]{64}$/.test(reply.proof)) throw new Error("invalid_response");
        const expected = hmac(sha256, proofKey, encoder.encode(`${info}|${status}`));
        if (!equalBytes(expected, hexToBytes(reply.proof))) throw new Error("invalid_response");
      } finally { proofKey.fill(0); }
    },
    destroy() { used = true; proofKey.fill(0); },
  };
}
