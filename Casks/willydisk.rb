# The Homebrew cask, as the tap serves it.
#
# Rendered by Scripts/homebrew-cask.sh: the version comes from this repository's
# VERSION file and each digest from that architecture's release archive. Edit
# the template, never the rendered copy in the tap.
cask "willydisk" do
  arch arm: "arm64", intel: "x86_64"

  version "1.0.5"
  sha256 arm:   "a5522fb28b71f1f1a10580fb83ee385f01b286a35be47f5188bd651cf9c8af64",
         intel: "973e3489eb2194d8b278b766242b763ab37cfccb56bfca872b733621020c3778"

  url "https://github.com/waelabdrabbo/WillyDisk/releases/download/v#{version}/WillyDisk-#{version}-#{arch}.zip"
  name "WillyDisk"
  desc "Disk-space analyzer that measures a folder and finds what can be reclaimed"
  homepage "https://github.com/waelabdrabbo/WillyDisk"

  livecheck do
    url :homepage
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "WillyDisk.app"
  binary "#{appdir}/WillyDisk.app/Contents/MacOS/WillyDisk", target: "willydisk"

  uninstall quit: "com.willydisk.app"

  zap trash: [
    "~/Library/Application Support/WillyDisk",
    "~/Library/Preferences/com.willydisk.app.plist",
  ]

  caveats <<~EOS
    WillyDisk is not signed by Apple and not notarized, so macOS blocks the
    first launch. That includes `willydisk` in a terminal, which is killed on
    start until the app itself is approved once. Nothing is broken: there is no
    Developer ID behind this build for macOS to check.

    Approve it in System Settings > Privacy & Security > Open Anyway, or clear
    the download flag first and open it again:

      xattr -dr com.apple.quarantine #{appdir}/WillyDisk.app

    Full Disk Access is optional. Without it, WillyDisk measures what it can
    read and reports what it could not. Because the app is ad-hoc signed, macOS
    may ask for that permission again after an update.

    WillyDisk can update itself from the app menu; `brew upgrade --cask
    willydisk` also works, and Homebrew compares the installed app's version so
    it will not replace a newer self-updated copy.

    The same binary also scans without a window: `willydisk scan <folder>`.
  EOS
end
