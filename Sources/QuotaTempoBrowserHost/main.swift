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
  // The store shares one lock with app-side disconnect as well as other hosts.
  try ClaudeBrowserStore(directory: directory).ingest(message, now: Date())
  try FileHandle.standardOutput.write(
    contentsOf: NativeMessageFraming.frame(Data(#"{"ok":true}"#.utf8)))
} catch {
  let code = (error as? ClaudeBrowserBridgeError)?.rawValue ?? "bridgeUnavailable"
  let response = Data("{\"ok\":false,\"error\":\"\(code)\"}".utf8)
  try? FileHandle.standardOutput.write(contentsOf: NativeMessageFraming.frame(response))
  exit(2)
}
