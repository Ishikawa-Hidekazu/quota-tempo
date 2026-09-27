cask "quotatempo" do
  version "0.1.7"
  sha256 "1b3fa8e5d18beb276dbfe3ea8cc64c7551e2ba4ef249cf3bbcb7e40a9a521f23"

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
