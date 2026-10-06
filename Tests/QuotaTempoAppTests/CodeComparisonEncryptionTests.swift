import CryptoKit
import Foundation
import Testing

@testable import QuotaTempoApp

// Synthetic client pins the key supplied with the command, never the grant.
struct CodeComparisonSyntheticRequest {
  let data: Data
  let requestID: String
  let info: String
  let responseKey: SymmetricKey

  init(
    publicKey: String, connectionID: String, streamID: String, endpoint: String,
    requestID: String = UUID().uuidString.lowercased(), plaintext: Data
  ) throws {
    let raw = try #require(CodeComparisonEncryption.unhex(publicKey, bytes: 32...32))
    let recipientKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    info = "QuotaTempo.CodeComparison.v3|\(connectionID)|\(streamID)|\(requestID)|\(endpoint)"
    self.requestID = requestID
    var sender = try HPKE.Sender(
      recipientKey: recipientKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
      info: Data(info.utf8))
    let ciphertext = try sender.seal(plaintext)
    responseKey = try sender.exportSecret(
      context: Data("QuotaTempo.CodeComparison.response.v3".utf8), outputByteCount: 32)
    data = try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": 3, "connectionID": connectionID, "streamID": streamID,
        "requestID": requestID,
        "enc": sender.encapsulatedKey.map { String(format: "%02x", $0) }.joined(),
        "ciphertext": ciphertext.map { String(format: "%02x", $0) }.joined(),
      ], options: [.sortedKeys])
  }

  func verifies(_ http: String) throws -> Bool {
    guard let delimiter = http.range(of: "\r\n\r\n") else { return false }
    return try verifies(Data(http[delimiter.upperBound...].utf8))
  }

  func verifies(_ data: Data) throws -> Bool {
    guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(response.keys) == ["schemaVersion", "status", "requestID", "proof"],
      CodeComparisonProtocol.number(response["schemaVersion"]) == 3,
      response["requestID"] as? String == requestID,
      let status = response["status"] as? String,
      ["connected", "accepted", "disconnected"].contains(status),
      let proofHex = response["proof"] as? String,
      let proof = CodeComparisonEncryption.unhex(proofHex, bytes: 32...32)
    else { return false }
    return HMAC<SHA256>.isValidAuthenticationCode(
      proof, authenticating: Data("\(info)|\(status)".utf8), using: responseKey)
  }
}

@Suite("Code comparison HPKE synthetic cryptography")
struct CodeComparisonEncryptionTests {
  private let connection = "11111111-1111-4111-8111-111111111111"
  private let stream = "22222222-2222-4222-8222-222222222222"
  private let requestID = "33333333-3333-4333-8333-333333333333"
  private let other = "44444444-4444-4444-8444-444444444444"

  private func fixtureKey(_ byte: UInt8 = 7) throws -> Curve25519.KeyAgreement.PrivateKey {
    try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
  }

  private func control(connectionID: String? = nil, streamID: String? = nil) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": 2, "connectionID": connectionID ?? connection,
        "streamID": streamID ?? stream,
      ], options: [.sortedKeys])
  }

  private func seal(
    _ key: Curve25519.KeyAgreement.PrivateKey, endpoint: String = "connect",
    requestID: String? = nil, plaintext: Data? = nil
  ) throws -> CodeComparisonSyntheticRequest {
    try CodeComparisonSyntheticRequest(
      publicKey: CodeComparisonEncryption.hex(key.publicKey.rawRepresentation),
      connectionID: connection, streamID: stream, endpoint: endpoint,
      requestID: requestID ?? self.requestID, plaintext: plaintext ?? control())
  }

  private func changed(_ data: Data, field: String, value: Any) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object[field] = value
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  @Test("Independent CryptoKit sender opens once and verifies the exact exporter proof")
  func roundTrip() throws {
    let key = try fixtureKey()
    let sealed = try seal(key)
    var receiver = CodeComparisonEncryption(privateKey: key)
    let opened = try receiver.open(sealed.data, connectionID: connection, endpoint: "connect")
    #expect(opened.plaintext == (try control()))
    #expect(try sealed.verifies(opened.response(status: "connected")))
    let proof = try opened.response(status: "connected")
    #expect(try !sealed.verifies(changed(proof, field: "status", value: "accepted")))
    #expect(try !sealed.verifies(changed(proof, field: "requestID", value: other)))
    #expect(throws: CodeComparisonEncryptionError.replay) {
      try receiver.open(sealed.data, connectionID: connection, endpoint: "connect")
    }
    // A fresh sender/context still cannot reuse an authenticated request ID.
    let another = try seal(key)
    #expect(throws: CodeComparisonEncryptionError.replay) {
      try receiver.open(another.data, connectionID: connection, endpoint: "connect")
    }
  }

  @Test("Tampering and cross-endpoint delivery do not consume an unauthenticated ID")
  func tamper() throws {
    let key = try fixtureKey()
    let sealed = try seal(key)
    let outer = try #require(JSONSerialization.jsonObject(with: sealed.data) as? [String: Any])
    let ciphertext = try #require(outer["ciphertext"] as? String)
    let altered = (ciphertext.first == "0" ? "1" : "0") + String(ciphertext.dropFirst())
    var receiver = CodeComparisonEncryption(privateKey: key)
    #expect(throws: (any Error).self) {
      try receiver.open(
        changed(sealed.data, field: "ciphertext", value: altered),
        connectionID: connection, endpoint: "connect")
    }
    #expect(throws: (any Error).self) {
      try receiver.open(sealed.data, connectionID: connection, endpoint: "disconnect")
    }
    #expect(
      try receiver.open(sealed.data, connectionID: connection, endpoint: "connect")
        .streamID == stream)
  }

  @Test(
    "Outer metadata is authenticated", arguments: ["connectionID", "streamID", "requestID", "enc"])
  func outerBinding(_ field: String) throws {
    let key = try fixtureKey()
    let sealed = try seal(key)
    var receiver = CodeComparisonEncryption(privateKey: key)
    let value = field == "enc" ? String(repeating: "0", count: 64) : other
    #expect(throws: (any Error).self) {
      try receiver.open(
        changed(sealed.data, field: field, value: value),
        connectionID: connection, endpoint: "connect")
    }
    _ = try receiver.open(sealed.data, connectionID: connection, endpoint: "connect")
  }

  @Test(
    "Inner binding is exact and authenticated invalid requests cannot be replayed",
    arguments: ["connectionID", "streamID", "schemaVersion", "extra"])
  func innerBinding(_ field: String) throws {
    let key = try fixtureKey()
    let value: Any
    if field == "schemaVersion" { value = 3 } else { value = other }
    let invalid = try changed(control(), field: field, value: value)
    let sealed = try seal(key, plaintext: invalid)
    var receiver = CodeComparisonEncryption(privateKey: key)
    #expect(throws: CodeComparisonEncryptionError.rejected) {
      try receiver.open(sealed.data, connectionID: connection, endpoint: "connect")
    }
    #expect(throws: CodeComparisonEncryptionError.replay) {
      try receiver.open(sealed.data, connectionID: connection, endpoint: "connect")
    }
  }

  @Test(
    "Exact outer schema, lowercase UUIDv4 and bounded even hex",
    arguments: [
      "plaintext", "extra", "version", "boolean", "uuid", "uuidcase", "encshort",
      "encupper", "odd", "upper", "short", "long",
    ])
  func strictEnvelope(_ kind: String) throws {
    let key = try fixtureKey()
    let sealed = try seal(key)
    let data: Data
    switch kind {
    case "plaintext": data = try control()
    case "extra": data = try changed(sealed.data, field: "extra", value: 1)
    case "version": data = try changed(sealed.data, field: "schemaVersion", value: 2)
    case "boolean": data = try changed(sealed.data, field: "schemaVersion", value: true)
    case "uuid":
      data = try changed(
        sealed.data, field: "requestID", value: "33333333-3333-1333-8333-333333333333")
    case "uuidcase":
      data = try changed(
        sealed.data, field: "streamID", value: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
    case "encshort":
      data = try changed(sealed.data, field: "enc", value: String(repeating: "0", count: 62))
    case "encupper":
      data = try changed(sealed.data, field: "enc", value: String(repeating: "A", count: 64))
    case "odd":
      data = try changed(sealed.data, field: "ciphertext", value: String(repeating: "0", count: 33))
    case "upper":
      data = try changed(sealed.data, field: "ciphertext", value: String(repeating: "A", count: 32))
    case "short":
      data = try changed(sealed.data, field: "ciphertext", value: String(repeating: "0", count: 30))
    default:
      data = try changed(
        sealed.data, field: "ciphertext", value: String(repeating: "0", count: 8_226))
    }
    var receiver = CodeComparisonEncryption(privateKey: key)
    #expect(throws: (any Error).self) {
      try receiver.open(data, connectionID: connection, endpoint: "connect")
    }
    _ = try receiver.open(sealed.data, connectionID: connection, endpoint: "connect")
  }

  @Test("Fresh keys cannot open old requests and close discards the key")
  func newKeyAndClose() throws {
    let old = try fixtureKey()
    let sealed = try seal(old)
    var fresh = CodeComparisonEncryption(privateKey: try fixtureKey(9))
    #expect(throws: (any Error).self) {
      try fresh.open(sealed.data, connectionID: connection, endpoint: "connect")
    }
    var receiver = CodeComparisonEncryption(privateKey: old)
    receiver.close()
    #expect(throws: CodeComparisonEncryptionError.closed) {
      try receiver.open(sealed.data, connectionID: connection, endpoint: "connect")
    }
  }

  @Test("4096 authenticated IDs are bounded; saturation destroys transport state")
  func saturation() throws {
    let key = try fixtureKey()
    var receiver = CodeComparisonEncryption(privateKey: key)
    for index in 0..<4_096 {
      let id = String(format: "00000000-0000-4000-8000-%012x", index)
      let sealed = try seal(key, requestID: id)
      _ = try receiver.open(sealed.data, connectionID: connection, endpoint: "connect")
    }
    let last = try seal(key)
    #expect(throws: CodeComparisonEncryptionError.exhausted) {
      try receiver.open(last.data, connectionID: connection, endpoint: "connect")
    }
    #expect(throws: CodeComparisonEncryptionError.closed) {
      try receiver.open(last.data, connectionID: connection, endpoint: "connect")
    }
  }

  @Test("Maximum plaintext is accepted, one extra byte is rejected")
  func plaintextLimit() throws {
    let key = try fixtureKey()
    let body = try control()
    let maximum = body + Data(repeating: 32, count: 4_096 - body.count)
    let sealed = try seal(key, plaintext: maximum)
    var receiver = CodeComparisonEncryption(privateKey: key)
    #expect(
      try receiver.open(sealed.data, connectionID: connection, endpoint: "connect")
        .plaintext.count == 4_096)
    let tooLarge = try seal(key, requestID: other, plaintext: maximum + Data([32]))
    #expect(throws: (any Error).self) {
      try receiver.open(tooLarge.data, connectionID: connection, endpoint: "connect")
    }
  }
}
