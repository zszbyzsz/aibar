cask "aibar" do
  version "0.1.9"
  sha256 "24741516dd281cd67bc248d1965f935a84795c9b356e03d58b4f6e84eba526a0"

  url "https://github.com/zszbyzsz/aibar/releases/download/v#{version}/aibar-#{version}.zip"
  name "aibar"
  desc "Local AI coding-usage dashboard for the MacBook notch"
  homepage "https://github.com/zszbyzsz/aibar"

  depends_on macos: :ventura
  depends_on arch: :arm64

  app "aibar.app"

  caveats <<~EOS
    aibar is ad-hoc signed. On its first launch, Control-click the app and
    choose Open if macOS shows a security warning. Upgrading from this build
    to the first Developer ID signed release requires granting Screen Recording
    once more; later consistently signed releases retain that permission.
  EOS
end
