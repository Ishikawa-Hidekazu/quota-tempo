cask "quotatempo" do
  version "0.1.14"
  sha256 "8c634151d32b50b5c00a62c811a779e9e75ebc7ee5ea8a9890804a3f5c08f987"

  url "https://github.com/Ishikawa-Hidekazu/quota-tempo/releases/download/v#{version}/QuotaTempo-#{version}-macOS.zip"
  name "QuotaTempo"
  desc "Weekly AI capacity planner for Codex and Claude"
  homepage "https://ishikawa.co/en/products/quotatempo/"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "QuotaTempo.app"

  zap trash: [
    "~/Library/Application Support/QuotaTempo",
    "~/Library/Preferences/co.ishikawa.QuotaTempo.plist",
  ]
end
