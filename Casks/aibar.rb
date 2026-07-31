cask "aibar" do
  version "0.1.8"
  sha256 "2a58c77b5cd87e24f498bf6baf5b5f3f519c3b57b8603bb053d71da67e8868ba"

  url "https://github.com/zszbyzsz/aibar/releases/download/v#{version}/aibar-#{version}.zip"
  name "aibar"
  desc "Local AI coding-usage dashboard for the MacBook notch"
  homepage "https://github.com/zszbyzsz/aibar"

  # Keep the comparator explicit for compatibility with Homebrew versions
  # where a bare macOS symbol is interpreted as an exact version.
  depends_on macos: ">= :ventura"
  depends_on arch: :arm64

  app "aibar.app"

  caveats <<~EOS
    aibar is ad-hoc signed. On its first launch, Control-click the app and
    choose Open if macOS shows a security warning. Upgrading from this build
    to the first Developer ID signed release requires granting Screen Recording
    once more; later consistently signed releases retain that permission.
  EOS
end
