cask "aibar" do
  version "0.1.12"
  sha256 "d1057532187f76327d72dd5268953ebcfd685eb707fc877f5dd29fa319b52544"

  url "https://github.com/zszbyzsz/aibar/releases/download/v#{version}/aibar-#{version}.zip"
  name "aibar"
  desc "Local AI coding-usage dashboard for the MacBook notch"
  homepage "https://github.com/zszbyzsz/aibar"

  depends_on macos: :ventura
  depends_on arch: :arm64

  app "aibar.app"

  caveats <<~EOS
    aibar is Ad-hoc signed. After installing or upgrading, grant Screen
    Recording again if prompted. Control-click the app and choose Open if
    macOS shows a security warning. Moving to the first Developer ID signed
    release will require one final privacy reauthorization.
  EOS
end
