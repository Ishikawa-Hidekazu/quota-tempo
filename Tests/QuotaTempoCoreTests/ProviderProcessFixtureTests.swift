import Testing

// Global shutdown fixtures share a process registry across both nested suites.
@Suite("Registered provider process fixtures", .serialized)
struct ProviderProcessFixtureTests {}
