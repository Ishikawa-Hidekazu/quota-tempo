cask "quotatempo" do
  version "0.1.10"
  sha256 "84da40011baf2a5e2636c7a2f35167ce9a0e8dd02471c5d85451d145de0cb0f2"

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
