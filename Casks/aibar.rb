cask "aibar" do
  version "0.1.13"
  sha256 "1bed1d19159f7b2bb8643f74179b9767730ee317af7ce180449a896cd577666c"

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
