# The Homebrew cask, as the tap serves it.
#
# Rendered by Scripts/homebrew-cask.sh: the version comes from this repository's
# VERSION file and each digest from that architecture's release archive. Edit
# the template, never the rendered copy in the tap.
cask "willydisk" do
  arch arm: "arm64", intel: "x86_64"

  version "1.0.1"
  sha256 arm:   "443d62de6be872f81348654424ade1778b5c4924063d0140257c16955de5bc8a",
         intel: "69e2d7d5a2cbb5c2cbf6b0b09f211b7c58cc116d3262d17d6eb644f451825466"

  url "https://github.com/waelabdrabbo/WillyDisk/releases/download/v#{version}/WillyDisk-#{version}-#{arch}.zip"
  name "WillyDisk"
  desc "Disk-space analyzer that measures a folder and finds what can be reclaimed"
  homepage "https://github.com/waelabdrabbo/WillyDisk"

  livecheck do
    url :homepage
    strategy :github_latest
  end

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
    read and reports what it could not.

    The same binary also scans without a window: `willydisk scan <folder>`.
  EOS
end
