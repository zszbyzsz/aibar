cask "aibar" do
  version "0.1.1"
  sha256 "7a40aa72a9874d24cafb6e5ef361a320a2ccfc5d864447901ded6ce109b2bdcc"

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
