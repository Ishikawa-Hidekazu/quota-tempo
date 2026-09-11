import Foundation

public enum FixtureLoader {
  public static func load(_ name: String) throws -> FixtureScenario {
    let url =
      QuotaTempoResourceLocator.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
      ) ?? QuotaTempoResourceLocator.url(forResource: name, withExtension: "json")

    guard let url else {
      throw FixtureError.missing(name)
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(FixtureScenario.self, from: Data(contentsOf: url))
  }
}

public enum FixtureError: Error, Equatable {
  case missing(String)
}
