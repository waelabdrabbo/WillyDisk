# Updates

How WillyDisk finds, verifies, and installs a newer release without a Developer ID
and without a third-party updater. The feed, download, verification, consent sheet,
detached install transaction, and cask declaration are implemented
(`Sources/DiskUpdate/`, `DiskUI/Support/Update*`,
`DiskUI/Components/UpdateSheet.swift`). The remaining release gate is one real
update over `/Applications`: TCC/Full Disk Access, the App Management prompt, and
the relaunch. This note records the decisions that are easy to get wrong so they are
not re-derived.

## Why hand-rolled

Sparkle is the usual answer, and it is not available here. The project ships no
third-party packages, and the app has no Apple Developer account: the bundle is
ad-hoc signed, every archive is unsigned in the Developer ID sense, and nothing is
notarized. Sparkle would add a framework, an appcast, and an EdDSA key pair without
solving any of that.

What the release pipeline already produces is enough for a small updater:

- a stable tag `v<version>` that must equal `VERSION`;
- one thin archive per architecture, `WillyDisk-<version>-arm64.zip` and
  `WillyDisk-<version>-x86_64.zip`;
- a `.sha256` beside each archive, in `shasum -a 256` output;
- a release body that is already written for a person.

The updater therefore adds only a feed client, a comparison, a download, and a
staged install. The release process does not need a new artifact.

## Feed contract

The feed is GitHub's unauthenticated REST endpoint:

```
GET https://api.github.com/repos/waelabdrabbo/WillyDisk/releases/latest
Accept: application/vnd.github+json
User-Agent: WillyDisk/<version>
```

`GitHubReleaseFeed` (`Sources/DiskUpdate/ReleaseFeed.swift`) reads `tag_name`,
`body`, `html_url`, `published_at`, and `assets[]`. It sends no token, cookie, scan
result, path, or file name. The request times out after 15 seconds and is reloaded
ignoring any local cache.

The feed client can carry an ETag, but the app does not send one. A `304` says the
release list has not changed since an earlier check, not that the installed app is
current; a process that did not cache the release cannot turn that into an offer. The
latest-release body is small and one request a day is well inside the unauthenticated
limit.

Rules:

- The repository and the release must be **publicly readable**. A private
  repository returns `404` to this request, and no installed copy can update.
- Only a published, stable release is a candidate. A draft or prerelease is
  rejected; `/releases/latest` already excludes both, so a value that says
  otherwise means the feed changed and is not trusted.
- The tag must be exactly `v` + the marketing version. The version may have one to
  three numbers, matching `VERSION`.
- Asset selection is by **exact name**, built from the release's marketing version:
  `WillyDisk-<version>-<arch>.zip` and the same name with `.sha256`. Guessing from a
  download URL is not allowed; a release that names its files differently is not
  installable.
- The release page and every asset URL must be HTTPS. An `http` URL fails the whole
  release rather than being silently skipped.
- `304 Not Modified` is not treated as "up to date": it is a protocol answer to a
  conditional request the app does not send, so it is reported as a failed check.
  `404` means there is no release to compare against. `403`/`429` with
  `X-RateLimit-Remaining: 0` is a rate limit, distinct from other HTTP failures.
  Offline, timed out, and cancelled requests are distinct too, because the screen
  words them differently.
- The limit is 60 unauthenticated requests per hour per address. A daily check
  uses one; the small release body is what lets the app compare versions and name
  the assets.

At the time this was written the latest release was `v1.0.1`: `arm64` 2,557,297
bytes, `x86_64` 2,692,619 bytes, both checksums matching `Casks/willydisk.rb`, the
notes filled with no placeholders, and one small GET for the whole check.

## Version identity

`ReleaseVersion` (`Sources/DiskUpdate/ReleaseVersion.swift`) parses one to three
dot-separated numbers, with or without a leading `v`, and compares numerically.
`1.0.10` is newer than `1.0.9`; `1.0` equals `1.0.0`. The marketing string is kept
beside the comparable value because the archive names use the publisher's exact
text (`WillyDisk-1.0.1-…`, not a re-formatted `1.0.1.0`).

The installed version is the bundle's `CFBundleShortVersionString`, which
`Scripts/bundle-app.sh` stamps from `VERSION`. `CFBundleVersion` is the commit count
and is not compared: it says which build this is, not which release.

`UpdateEvaluator` is pure and returns one of:

| Result | Meaning |
|---|---|
| `unknownCurrentVersion` | the running build has no readable marketing version (`swift run`, a bare executable) |
| `upToDate` | the feed's version equals the installed one |
| `newerThanLatest` | the installed build is newer than the latest published release; never offer a downgrade |
| `noBuildForThisMac` | the release exists but has no archive for the running architecture |
| `incompleteRelease` | the archive exists but a required file (the `.sha256`) is missing |
| `available` | both assets exist and the release is newer |

A skipped version is a preference, not a feed rule. It belongs to the controller
and must never make the evaluator call a newer release `upToDate`.

## Verification pipeline

`UpdateVerifier` (`Sources/DiskUpdate/UpdateVerifier.swift`) runs in this order, and
nothing after a failure runs:

1. **Name and size.** The downloaded file must be the archive the release names.
   The `.sha256` must name that same file, and the API's published byte count must
   match the file when the caller supplies it. A valid digest for the other
   architecture is still the wrong file.
2. **Checksum.** Parse the published line, hash the archive in 1 MiB chunks with
   CryptoKit, and require equality. The archive is never loaded whole into memory.
3. **Extract.** `/usr/bin/ditto -x -k` into a fresh directory. `ditto` is the
   extractor because the release is built with `ditto`: it preserves the extended
   attributes and resource forks the signature seals over. The result must be
   `WillyDisk.app` at the top of that directory, and its resolved path must not
   escape the directory.
4. **Identity.** `CFBundleIdentifier` must equal the running app's
   (`com.willydisk.app`), `CFBundleShortVersionString` must equal the release's
   marketing version, and the declared executable must exist and be executable.
5. **Compatibility.** If `LSMinimumSystemVersion` is present it must be satisfied by
   the running macOS. A malformed value is a failure, not an assumption.
6. **Architecture.** `lipo -archs` must contain the running slice. A universal
   archive is acceptable; the other architecture alone is not.
7. **Signature.** `codesign --verify --strict` must pass. The signature is ad-hoc;
   this proves the bundle is intact, not that Apple or a Developer ID vouches for it.

The downloaded app is never executed. The release pipeline is what runs the CLI
smoke test on a built slice; the updater validates metadata and signature only.

**What the checksum proves.** The `.sha256` comes from the same release as the zip.
It catches a corrupted or truncated download and a swapped asset within that feed;
it does not prove who published the release. The UI must say "the SHA-256 matches
the published checksum", never "verified" or "trusted". A future hardening step is
an Ed25519 signature of the archive with a key held only in CI secrets, which
CryptoKit can verify without a package; that is not part of the current design.

## Install transaction

Download and install are two clicks. The first consents to the download; the
second consents to quitting, replacing the bundle, and reopening. Nothing is
downloaded or installed in the background.

- Download into `~/Library/Application Support/WillyDisk/Updates/<version>/` with
  owner-only permissions. The version is one to three numeric components; anything
  else is refused, so a feed value cannot become a path outside the update store.
  Check free space for the archive, the expanded bundle, and a backup before
  starting. Real byte progress from the download task; cancellation deletes the
  partial file.
- Verification runs before anything touches the installed app. A failure deletes
  the staged files and leaves the app exactly as it was.
- `UpdateInstaller` validates the destination before spawning anything: it must be
  an `.app` bundle, not a symlink, not under `/AppTranslocation/`, on a volume that
  is not read-only, and in a folder the app can write. There is no administrator
  prompt and no privileged helper; a refusal is a message, not an escalation.
- The installer clears `com.apple.quarantine` from the staged app, writes a small
  `/bin/sh` helper into `Updates/Recovery/<version>/`, starts it detached, closes
  the sheet, and quits. If AppKit defers the termination request, a short fallback
  exits the process so the helper never waits on a live app. The helper waits up to
  60 seconds for the process to exit.
- The helper renames the installed app to
  `Updates/Recovery/<version>/backup/WillyDisk.app`, copies the staged app into
  place with `ditto`, writes a result, and reopens the app with `open -n`. If the
  copy fails it removes the partial target, moves the backup back, writes the
  failure, and reopens the old app. The helper never runs as root.
- The result lives at `Updates/install-result`, at the store's root so whichever
  version launches can find it. It is small key/value data (`status`, `version`,
  `relaunched`, `failure`); the next launch reads and removes it.
- On success the staging directory is removed, while `Recovery/<version>/` keeps
  the old app and `install.log` for manual recovery. A new build that crashes on
  launch is a separate problem; the backup is the manual path back.
- On failure the sheet gets the typed install failure; when the helper ran, a Show
  Log action. The old app is normally already back in place; the log says what ran.
  The backup and log are never deleted by a later download.
- If the helper cannot be started, the app stays open in the failure state. If it
  is denied the destination, the same. There is no half-installed success report.

## Homebrew

The cask is the second install path and must not fight the updater. Homebrew's
guidance is explicit: a cask for an app with a working "Check for Updates…" that
downloads and installs should declare `auto_updates true`
([Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)). For a versioned cask with a
readable app bundle, `brew upgrade` compares the installed bundle's version with the
cask's version and skips a newer self-updated app rather than downgrading it
([Homebrew FAQ](https://docs.brew.sh/FAQ)).

`.github/homebrew/willydisk.rb.tmpl` now declares `auto_updates true` (the rendered
`Casks/willydisk.rb` is never hand-edited; the next release renders it). `brew
upgrade --cask willydisk` stays a valid path, and Homebrew's version comparison
keeps it from replacing a newer self-updated app. The published 1.0.1 cask predates
the updater; the next release is the first one whose cask carries the declaration.
`bash Scripts/homebrew-cask.sh check --audit` validates the template.

## Permissions and platform constraints

These are the reasons the install step is gated on a real test, not just code.

- **TCC and Full Disk Access.** Every ad-hoc-signed build has a different code
  identity. macOS may treat the updated app as a new app for privacy permissions, so
  Full Disk Access may have to be granted again after an update. Homebrew documents
  this class of problem for unsigned apps and for cask upgrades. It is the main
  cost of self-updating a disk analyzer. Test it on macOS 14 and on the current
  release before shipping. If it resets, either explain the re-grant in the update
  screen or move to a stable self-signed code-signing identity, which keeps the
  designated requirement stable without pretending to be notarized.
- **App Management.** macOS may require App Management permission for a process to
  replace an app bundle. If the helper is denied, the restore path must run and the
  message must point at System Settings → Privacy & Security → App Management.
- **Translocation.** An app opened from Downloads or a disk image runs from a
  random read-only path. It cannot update itself; say to move it to Applications.
- **A non-admin user** cannot replace `/Applications/WillyDisk.app`. Offer the
  checksum-matched download; do not add a privileged helper or an AppleScript escalation.
- **The checksum is not authenticity.** See above; the wording is part of the
  acceptance.

## Privacy

The updater's only network use is the one feed request and, after consent, the two
asset downloads. It sends no file name, path, scan result, history, or preference.
There is no telemetry, no account, and no token. The daily check is a preference;
the menu item always works, and the app never downloads or installs without a click.
The release notes are publisher text in English and are shown as such, not passed
through the app's localization. The sheet renders only the change section; the
release page carries the full notes, install steps, and checksums.

## UI

The sheet is one window on the main view, hosted by `UpdateSheetHost` and backed by
`UpdateController`. Its states are:

`checking → upToDate | newerThanLatest | unknownCurrentVersion | noBuildForThisMac | incompleteRelease | available → downloading → verifying → ready → installing | failed`

- Available: current and new version, the **What's Changed** section from the
  release body, download size, the checksum/unsigned wording, Open Release Page,
  Download, Later, Skip This Version. The sheet does not render the whole release
  page; install steps and checksums stay there.
- Downloading: real byte progress with Cancel; closing the sheet cancels the task
  and returns to the offer.
- Checking: the checksum, extraction, and bundle checks run; the sheet stays put.
- Ready: downloaded with a matching checksum. Install and Relaunch is the consent
  to quit, swap, and reopen; Show in Finder and Done are the alternatives. The
  caption says the app will quit and that a scan in progress stops.
- Installing: the helper is running and the app is quitting; there are no more
  actions on the sheet.
- Failed: a typed reason, Try Again, Show Log when an install left one, and the
  release page when the failure happened after a release was known. An install
  failure returns to Ready on retry once the destination is fixed; a launch-time
  install failure offers a new check instead.
- The menu item is "Check for Updates…" under About. Settings holds the daily-check
  toggle and the last successful check; there is no second update window.
- The launch check waits eight seconds, then runs at most once per 24 hours. A
  manual check ignores the interval and a skipped version; a skipped version hides
  only that version from the automatic offer.
- Every string goes through `DiskLocalization`, with Arabic; `-S update` and
  `-S update-ready` render the offer and the install button in English, Arabic, and
  `en-XA`. Release notes are publisher text in English and are kept left-to-right
  inside an Arabic interface.
- The screen does not call an unsigned download verified or trusted. A green
  "verified" badge is not acceptable wording.

## Failure modes

| Failure | What the person sees | What changes |
|---|---|---|
| Offline / timeout | check again later | nothing |
| `404` (no release or not public) | no published release found | nothing |
| missing asset for this Mac | this release has no build for this Mac | nothing |
| missing `.sha256` | the release is incomplete | nothing |
| download fails or is too large | could not download; try again | staged files deleted |
| checksum mismatch | download did not match the published checksum | staged files deleted |
| extraction or bundle check fails | download is not a valid WillyDisk build | staged files deleted |
| not enough disk space | free space needed | nothing |
| not writable / translocated / read-only | move the app or install the archive by hand | nothing |
| helper cannot start | previous copy is unchanged | nothing |
| copy fails during the swap | previous copy is restored; log | backup moved back |
| helper denied at runtime | previous copy is restored; log | backup moved back |
| new build does not launch | the previous copy is in `Recovery/<version>/` | manual restore |

## Testing

- `swift test --filter DiskUpdateTests` covers versions, feed decoding, asset
  selection, checksum parsing/hashing, staged-bundle checks, download progress, and
  the real `/bin/sh` installer against fake app directories (swap, rollback, and
  result parsing). The suite never touches the network: feed tests use a fake
  `FeedTransport`.
- `swift test --filter UpdateQATests` drives the controller, preferences, staging,
  and install states with a fake feed, downloader, verifier, and installer: offer,
  skip, retry, failure, ready, install, and the launch result.
- A live check is a manual acceptance step against the public release, not a unit
  test. Do not add a test that downloads from GitHub.
- `-S update -c -s 640x600` and `-S update-ready -c -s 640x600` render the offer
  and its install button in English and Arabic (and `en-XA` where truncation is the
  question). `-S settings -c -s 460x760` shows the Updates section above Scan Options.
- The install step needs a real update over a copy in `~/Applications`, then over
  `/Applications/WillyDisk.app`, including a checksum failure, a wrong-version
  failure, and a destination the app cannot write. Then the TCC/Full Disk Access
  test above, and a Homebrew install/upgrade test with a cask that declares
  `auto_updates`.
- Before a release, confirm the repository and the release assets are readable
  without credentials. A release that only the owner can download cannot update
  anyone.

## Open decisions

- **Signing:** accept the ad-hoc TCC cost and document it, or adopt a stable
  self-signed identity if updates otherwise lose Full Disk Access.
- **Optional hardening:** Ed25519-signed archives, and a "Revert to Previous Version"
  action fed by the retained backup.
- **First real install:** the automated tests prove the swap and rollback, not the
  TCC grant, App Management prompt, or a launch from `/Applications`. That test is
  the release gate.
