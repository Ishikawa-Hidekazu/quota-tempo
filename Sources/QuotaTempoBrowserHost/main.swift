import Darwin
import Foundation
import QuotaTempoCore

struct HostConfiguration: Decodable { let extensionOrigin: String }

var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("QuotaTempo/BrowserBridge", isDirectory: true)
var arguments = Array(CommandLine.arguments.dropFirst())
#if DEBUG
  // Isolated process-level fixtures must never touch the user's connection.
  if arguments.count == 3, arguments[0] == "--test-directory", arguments[1].hasPrefix("/") {
    directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    arguments = Array(arguments.suffix(1))
  }
#endif
let configurationURL = directory.appendingPathComponent("host-config.json")
alarm(20)
do {
  let data = try FileBoundedLocalDataReader().read(from: configurationURL, limit: 1_024)
  let configuration = try JSONDecoder().decode(HostConfiguration.self, from: data)
  guard arguments.count == 1,
    arguments[0] == configuration.extensionOrigin,
    configuration.extensionOrigin.range(
      of: #"^chrome-extension://[a-p]{32}/$"#, options: .regularExpression) != nil
  else { throw ClaudeBrowserBridgeError.invalidMessage }

  // A slow sender must not hold the store lock while another profile signs out.
  let message = try NativeMessageFraming.read(from: .standardInput)
  // Chrome may start hosts from more than one profile concurrently. Serialize
  // the binding check and atomic replacement so only one profile can claim it.
  let lockURL = directory.appendingPathComponent("host.lock")
  let lock = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
  guard lock >= 0 else { throw ClaudeBrowserBridgeError.invalidMessage }
  defer { close(lock) }
  let deadline = ProcessInfo.processInfo.systemUptime + 1
  while flock(lock, LOCK_EX | LOCK_NB) != 0 {
    guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else {
      throw ClaudeBrowserBridgeError.bridgeBusy
    }
    usleep(10_000)
  }
  defer { flock(lock, LOCK_UN) }
  try ClaudeBrowserStore(directory: directory).ingest(message, now: Date())
  try FileHandle.standardOutput.write(
    contentsOf: NativeMessageFraming.frame(Data(#"{"ok":true}"#.utf8)))
} catch {
  let code = (error as? ClaudeBrowserBridgeError)?.rawValue ?? "bridgeUnavailable"
  let response = Data("{\"ok\":false,\"error\":\"\(code)\"}".utf8)
  try? FileHandle.standardOutput.write(contentsOf: NativeMessageFraming.frame(response))
  exit(2)
}
