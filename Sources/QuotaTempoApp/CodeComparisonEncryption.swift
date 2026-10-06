import CryptoKit
import Foundation

enum CodeComparisonEncryptionError: Error, Equatable {
  case rejected, replay, exhausted, closed
}

// Owned by the bridge and accessed only under its state/cancellation lock.
struct CodeComparisonEncryption {
  static let maximumPlaintextBytes = 4_096
  static let maximumRequestIDs = 4_096
  static let responseContext = Data("QuotaTempo.CodeComparison.response.v3".utf8)
  private var privateKey: Curve25519.KeyAgreement.PrivateKey?
  private var requestIDs: Set<String> = []

  init(privateKey: Curve25519.KeyAgreement.PrivateKey) { self.privateKey = privateKey }

  mutating func close() {
    privateKey = nil
    requestIDs.removeAll(keepingCapacity: false)
  }

  struct Opened {
    let plaintext: Data
    let body: [String: Any]
    let streamID: String
    let requestID: String
    let info: String
    let responseKey: SymmetricKey

    func response(status: String) throws -> Data {
      let proof = HMAC<SHA256>.authenticationCode(
        for: Data("\(info)|\(status)".utf8), using: responseKey)
      return try JSONSerialization.data(
        withJSONObject: [
          "schemaVersion": 3, "status": status, "requestID": requestID,
          "proof": CodeComparisonEncryption.hex(proof),
        ], options: [.sortedKeys])
    }
  }

  static func info(
    connectionID: String, streamID: String, requestID: String, endpoint: String
  ) -> String {
    "QuotaTempo.CodeComparison.v3|\(connectionID)|\(streamID)|\(requestID)|\(endpoint)"
  }

  static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  static func unhex(_ value: String, bytes: ClosedRange<Int>) -> Data? {
    let utf8 = Array(value.utf8)
    guard utf8.count.isMultiple(of: 2), bytes.contains(utf8.count / 2),
      utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { return nil }
    func nibble(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : byte - 87 }
    return Data(
      stride(from: 0, to: utf8.count, by: 2).map {
        nibble(utf8[$0]) * 16 + nibble(utf8[$0 + 1])
      })
  }

  mutating func open(_ data: Data, connectionID: String, endpoint: String) throws -> Opened {
    guard let privateKey else { throw CodeComparisonEncryptionError.closed }
    guard ["connect", "measure", "disconnect"].contains(endpoint),
      let outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      CodeComparisonProtocol.keys(
        outer, ["schemaVersion", "connectionID", "streamID", "requestID", "enc", "ciphertext"]),
      CodeComparisonProtocol.number(outer["schemaVersion"]) == 3,
      CodeComparisonProtocol.uuid(connectionID), outer["connectionID"] as? String == connectionID,
      let streamID = outer["streamID"] as? String, CodeComparisonProtocol.uuid(streamID),
      let requestID = outer["requestID"] as? String, CodeComparisonProtocol.uuid(requestID),
      let encHex = outer["enc"] as? String, let enc = Self.unhex(encHex, bytes: 32...32),
      let ciphertextHex = outer["ciphertext"] as? String,
      let ciphertext = Self.unhex(ciphertextHex, bytes: 16...(Self.maximumPlaintextBytes + 16))
    else { throw CodeComparisonEncryptionError.rejected }
    guard !requestIDs.contains(requestID) else { throw CodeComparisonEncryptionError.replay }
    let info = Self.info(
      connectionID: connectionID, streamID: streamID, requestID: requestID, endpoint: endpoint)
    // Each HTTP request starts at HPKE sequence zero; contexts are never reused.
    var recipient = try HPKE.Recipient(
      privateKey: privateKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
      info: Data(info.utf8), encapsulatedKey: enc)
    let plaintext = try recipient.open(ciphertext)
    guard plaintext.count <= Self.maximumPlaintextBytes else {
      throw CodeComparisonEncryptionError.rejected
    }
    let responseKey = try recipient.exportSecret(
      context: Self.responseContext, outputByteCount: 32)
    guard requestIDs.count < Self.maximumRequestIDs else {
      close()
      throw CodeComparisonEncryptionError.exhausted
    }
    // Authentication failures cannot fill the set. Authenticated invalid inner
    // messages do consume their IDs, before any application side effects.
    requestIDs.insert(requestID)
    guard let body = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any],
      body["connectionID"] as? String == connectionID, body["streamID"] as? String == streamID
    else { throw CodeComparisonEncryptionError.rejected }
    if endpoint == "measure" {
      guard
        CodeComparisonProtocol.keys(
          body, ["schemaVersion", "connectionID", "streamID", "sequence", "result"]),
        CodeComparisonProtocol.number(body["schemaVersion"]) == 1
      else { throw CodeComparisonEncryptionError.rejected }
    } else {
      guard CodeComparisonProtocol.keys(body, ["schemaVersion", "connectionID", "streamID"]),
        CodeComparisonProtocol.number(body["schemaVersion"]) == 2
      else { throw CodeComparisonEncryptionError.rejected }
    }
    return Opened(
      plaintext: plaintext, body: body, streamID: streamID, requestID: requestID,
      info: info, responseKey: responseKey)
  }
}
