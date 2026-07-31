cask "aibar" do
  version "0.1.7"
  sha256 "679094a8db1f2cebca3992c3144a08c4b6253bbadcd6e6976e5bd63c1c5af49a"

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
    choose Open if macOS shows a security warning.
  EOS
end
