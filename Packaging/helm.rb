# Template: release.sh fills in the version and checksum and writes dist/helm.rb.
cask "helm" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/@REPO@/releases/download/v#{version}/Helm-#{version}.zip"
  name "Helm"
  desc "Screensaver showing your Apple Notes and Reminders over a photo slideshow"
  homepage "https://github.com/@REPO@"

  depends_on macos: :sonoma

  app "Helm.app"
  screen_saver "Helm.saver"

  # Helm isn't notarized, so Gatekeeper would refuse to open the app. Clear
  # the download quarantine; the app does the same for the screensaver.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/Helm.app"],
        writable_paths: ["{{appdir}}/Helm.app"],
        must_succeed:   false
  end

  # launchctl also removes the login agent's plist.
  uninstall launchctl: "com.jonathanvineet.helm",
            quit:      "com.jonathanvineet.helm"

  zap trash: [
    "~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/Helm",
    "~/Library/Logs/Helm.log",
    "~/Library/Preferences/com.jonathanvineet.helm.plist",
  ]

  caveats <<~EOS
    To finish setting up:
      1. Open Helm (it lives in the menu bar and starts at login).
      2. System Settings → Screen Saver: pick Helm.
      3. Allow Reminders access, and Full Disk Access to read Apple Notes.
  EOS
end
