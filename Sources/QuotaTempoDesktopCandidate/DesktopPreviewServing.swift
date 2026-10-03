protocol DesktopPreviewServing: Sendable {
  func setApproval(_ approval: DesktopAccessApproval) async
  func refresh() async -> DesktopUsageCandidateResult
  func recheckConnection() async -> DesktopUsageCandidateResult
}

extension DesktopPreviewServing {
  func recheckConnection() async -> DesktopUsageCandidateResult { await refresh() }
}

extension DesktopUsageCandidateService: DesktopPreviewServing {}
