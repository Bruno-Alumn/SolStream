# Homebrew cask for SolStream's Mac app. It lives in the tap repository
# Bruno-Alumn/homebrew-solstream (Casks/solstream.rb); this copy is the source.
# scripts/update-packages.sh sets the version and sha256 from the latest release.
cask "solstream" do
  version "1.0.7"
  sha256 "2ca7528d42c550ae710c9c40e298890c6966ec0c351dfb2a680dbc9e390fb7b6"

  url "https://github.com/Bruno-Alumn/SolStream/releases/download/v#{version}/SolStream-#{version}-macOS.zip"
  name "SolStream"
  desc "Stream Windows apps from a PC, each in its own native window"
  homepage "https://github.com/Bruno-Alumn/SolStream"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The app updates itself from GitHub releases.
  auto_updates true
  depends_on macos: :sonoma

  app "SolStream.app"

  uninstall quit: "com.solstream.macclient"

  zap trash: [
    "~/Applications/SolStream Apps",
    "~/Library/Application Support/SolStream",
    "~/Library/Caches/com.solstream.macclient",
    "~/Library/HTTPStorages/com.solstream.macclient",
    "~/Library/Logs/SolStream",
    "~/Library/Preferences/com.solstream.macclient.plist",
    "~/Library/Saved Application State/com.solstream.macclient.savedState",
  ]

  caveats <<~EOS
    SolStream isn't notarized by Apple, so macOS refuses it the first time
    you open it. Dismiss the warning, then choose Open Anyway in System
    Settings → Privacy & Security.

    The PC needs SolStream too: run SolStreamSetup from
    https://github.com/Bruno-Alumn/SolStream/releases/latest on Windows.
  EOS
end
