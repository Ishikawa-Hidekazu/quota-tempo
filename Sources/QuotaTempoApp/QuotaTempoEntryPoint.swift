import Dispatch
import Foundation
import SwiftUI

@main
enum QuotaTempoEntryPoint {
  @MainActor
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if requestsCodePackageValidation(arguments) {
      #if DESKTOP_INTEGRATION_PREVIEW
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 30)
        watchdog.setEventHandler {
          print("{\"status\":\"packageValidationDeadlineExceeded\",\"passed\":false}")
          exit(2)
        }
        watchdog.resume()
        setbuf(stdout, nil)
        DispatchQueue.global().async {
          let result = CodeComparisonPackageValidation.run(arguments)
          watchdog.cancel()
          print(result.json)
          exit(result.exitCode)
        }
        dispatchMain()
      #else
        print("{\"status\":\"codePackageValidationNotIncluded\",\"passed\":false}")
        exit(2)
      #endif
    }
    if requestsDesktopAcceptance(arguments) {
      #if DESKTOP_INTEGRATION_PREVIEW
        // No SwiftUI application, preferences, Codex acquisition or OS dialog is
        // created by this explicitly consented, process-scoped acceptance mode.
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 690)
        watchdog.setEventHandler {
          print("{\"status\":\"acceptanceDeadlineExceeded\",\"passed\":false}")
          exit(2)
        }
        watchdog.resume()
        setbuf(stdout, nil)
        Task {
          let result = await DesktopAcceptanceCommand.run(arguments: arguments)
          watchdog.cancel()
          exit(result)
        }
        dispatchMain()
      #else
        print("{\"status\":\"desktopAcceptanceNotIncluded\",\"passed\":false}")
        exit(2)
      #endif
    }
    QuotaTempoApp.main()
  }

  static func requestsDesktopAcceptance(_ arguments: [String]) -> Bool {
    let reserved = [
      "--desktop-acceptance", "--consent-desktop-read-only",
      "--acknowledge-provider-permission-unconfirmed",
    ]
    return arguments.contains { argument in reserved.contains { argument.hasPrefix($0) } }
  }

  static func requestsCodePackageValidation(_ arguments: [String]) -> Bool {
    arguments.contains { $0.hasPrefix("--code-comparison-package-validation") }
  }
}
