cask "aibar" do
  version "0.1.9"
  sha256 "46d543b0182d648f6b38435327f13d3e9a23a0b0703a620ca95c444d018dcb41"

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
