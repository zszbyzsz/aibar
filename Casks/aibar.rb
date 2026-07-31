cask "aibar" do
  version "0.1.4"
  sha256 "3ad3b6cf6362e000e4a6f00ca3833f76b407dfada43d8c3e5a5a94d84a927a6d"

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
