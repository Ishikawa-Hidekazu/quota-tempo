import Foundation
import ServiceManagement

public enum LoginItemState: Equatable, Sendable {
  case disabled
  case enabled
  case requiresApproval
  case requiresMoveToApplications
  case unavailable

  public var isRequested: Bool {
    self == .enabled || self == .requiresApproval
  }

  public static func from(_ status: SMAppService.Status) -> LoginItemState {
    switch status {
    case .notRegistered, .notFound:
      .disabled
    case .enabled:
      .enabled
    case .requiresApproval:
      .requiresApproval
    @unknown default:
      .unavailable
    }
  }

  public static func canRegister(_ status: SMAppService.Status) -> Bool {
    self.from(status) == .disabled
  }
}

public enum LoginItemInstallLocation {
  public static func isSupported(
    bundleURL: URL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Bool {
    let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    guard bundle.pathExtension == "app" else { return false }

    let applicationDirectories = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      homeDirectory.appendingPathComponent("Applications", isDirectory: true),
    ].map { $0.standardizedFileURL.resolvingSymlinksInPath().path }

    return applicationDirectories.contains { directory in
      bundle.path == directory || bundle.path.hasPrefix("\(directory)/")
    }
  }
}

public enum LoginItemServiceError: Error {
  case unavailable
  case unsupportedInstallLocation
}

@MainActor
public protocol LoginItemServicing {
  var state: LoginItemState { get }
  func register() throws
  func unregister() throws
}

@MainActor
public struct SystemLoginItemService: LoginItemServicing {
  private enum Backing {
    case unsupportedInstallLocation
    case service(SMAppService)
  }

  private let backing: Backing

  public init(
    service: SMAppService? = nil,
    serviceFactory: () -> SMAppService = { .mainApp },
    bundleURL: URL = Bundle.main.bundleURL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    if LoginItemInstallLocation.isSupported(
      bundleURL: bundleURL,
      homeDirectory: homeDirectory
    ) {
      self.backing = .service(service ?? serviceFactory())
    } else {
      self.backing = .unsupportedInstallLocation
    }
  }

  public var state: LoginItemState {
    switch self.backing {
    case .unsupportedInstallLocation:
      return .requiresMoveToApplications
    case .service(let service):
      return LoginItemState.from(service.status)
    }
  }

  public func register() throws {
    let service = try self.supportedService()
    guard LoginItemState.canRegister(service.status) else { return }
    try service.register()
  }

  public func unregister() throws {
    let service = try self.supportedService()
    guard service.status == .enabled || service.status == .requiresApproval else {
      return
    }
    try service.unregister()
  }

  private func supportedService() throws -> SMAppService {
    guard case .service(let service) = self.backing else {
      throw LoginItemServiceError.unsupportedInstallLocation
    }
    return service
  }
}

@MainActor
public struct UnavailableLoginItemService: LoginItemServicing {
  public init() {}

  public var state: LoginItemState { .unavailable }

  public func register() throws {
    throw LoginItemServiceError.unavailable
  }

  public func unregister() throws {
    throw LoginItemServiceError.unavailable
  }
}
