cask "quotatempo" do
  version "0.1.6"
  sha256 "1fbf88a136199652fe2652d8b7c5b1390aae6492fdbcf8470be8fc92fb8bece5"

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
