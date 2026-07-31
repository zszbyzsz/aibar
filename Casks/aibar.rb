cask "aibar" do
  version "0.1.0"
  sha256 "f59f0ba5fd1a562b6a67a3e1446109859d5aab44543c0a052711619084ba9af8"

  url "https://github.com/zszbyzsz/aibar/releases/download/v#{version}/aibar-#{version}.zip"
  name "aibar"
  desc "Local AI coding-usage dashboard for the MacBook notch"
  homepage "https://github.com/zszbyzsz/aibar"

  depends_on macos: :ventura
  depends_on arch: :arm64

  app "aibar.app"

  caveats <<~EOS
    aibar is ad-hoc signed. On its first launch, Control-click the app and
    choose Open if macOS shows a security warning.
  EOS
end
