cask "quotatempo" do
  version "0.1.3"
  sha256 "c0f8587062c48c8b5c9cf3885262e92855dfb2ae415d9f2bd83dfb67a0b4a950"

  url "https://github.com/Ishikawa-Hidekazu/quota-tempo/releases/download/v#{version}/QuotaTempo-#{version}-macOS.zip"
  name "QuotaTempo"
  desc "Weekly AI capacity planner for Codex and Claude"
  homepage "https://ishikawa.co/en/projects/"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "QuotaTempo.app"

  zap trash: [
    "~/Library/Application Support/QuotaTempo",
    "~/Library/Preferences/co.ishikawa.QuotaTempo.plist",
  ]
end
