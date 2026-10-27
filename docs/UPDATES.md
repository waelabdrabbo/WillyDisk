# Updates

How WillyDisk finds, verifies, and installs a newer release without a Developer ID
and without a third-party updater. The release feed and the verification rules are
implemented in `Sources/DiskUpdate/`; the download, consent UI, and install
transaction are the remaining work. This note records the decisions that are easy
to get wrong so they are not re-derived.

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
If-None-Match: <etag>        (optional)
```

`GitHubReleaseFeed` (`Sources/DiskUpdate/ReleaseFeed.swift`) reads `tag_name`,
`body`, `html_url`, `published_at`, and `assets[]`. It sends no token, cookie, scan
result, path, or file name. The request times out after 15 seconds and is reloaded
ignoring any local cache; the ETag is the cache.

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
- `304 Not Modified` means up to date; it is not an error. `404` means there is no
  release to compare against. `403`/`429` with `X-RateLimit-Remaining: 0` is a rate
  limit, distinct from other HTTP failures. Offline, timed out, and cancelled
  requests are distinct too, because the screen words them differently.
- The limit is 60 unauthenticated requests per hour per address. A daily check
  uses one; the ETag makes the usual answer a bodiless `304`.

At the time this was written the latest release was `v1.0.1`: `arm64` 2,557,297
bytes, `x86_64` 2,692,619 bytes, both checksums matching `Casks/willydisk.rb`, the
notes filled with no placeholders, and an ETag present.

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

## Install transaction (not yet implemented)

The download, consent, and swap belong to the next layer. The rules they must keep:

- Download into `~/Library/Application Support/WillyDisk/Updates/<version>/` with
  owner-only permissions. Check free space for the archive, the expanded bundle, and
  a backup before starting. Real byte progress from the download task; cancellation
  deletes the partial file.
- Verification runs before anything touches the installed app. A failure deletes
  the staged files and leaves the app exactly as it was.
- Download and install are two clicks. The first consents to the download; the
  second consents to quitting, replacing the bundle, and relaunching. Nothing is
  downloaded or installed in the background.
- The swap cannot happen in the running process. Write a small `/bin/sh` helper in
  the update directory, spawn it, then quit. The helper waits for the app's PID to
  exit (with a timeout), moves the installed app to
  `Updates/<version>/backup/WillyDisk.app`, moves the staged app into place, and
  launches it with `open -n`. On any failure it moves the backup back and writes a
  result file.
- The next launch reads the result. Success cleans the archive, staged copy, and
  backup; failure keeps them, says what happened, and offers the log and the backup.
  A new build that crashes on launch is a separate problem: the backup is the
  manual recovery path and should be documented as such.
- Refuse to install when the running bundle is not an `.app`, when its path contains
  `/AppTranslocation/`, when the volume is read-only, or when the containing folder
  is not writable. The fallback is to save the verified zip or open the release page,
  never to ask for an administrator password.
- Strip `com.apple.quarantine` from the staged bundle before the swap, otherwise the
  relaunch can be blocked after the old copy is gone. The user already approved this
  installation; the update is the same app continuing.

## Homebrew

The cask is the second install path and must not fight the updater. Homebrew's
guidance is explicit: a cask for an app with a working "Check for Updates…" that
downloads and installs should declare `auto_updates true`
([Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)). For a versioned cask with a
readable app bundle, `brew upgrade` compares the installed bundle's version with the
cask's version and skips a newer self-updated app rather than downgrading it
([Homebrew FAQ](https://docs.brew.sh/FAQ)).

The intended change, when the install step ships, is `auto_updates true` in
`.github/homebrew/willydisk.rb.tmpl` (never the rendered `Casks/willydisk.rb`),
followed by `bash Scripts/homebrew-cask.sh check --audit`. `brew upgrade --cask
willydisk` stays a valid path; the docs say both exist.

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
  verified download; do not add a privileged helper or an AppleScript escalation.
- **The checksum is not authenticity.** See above; the wording is part of the
  acceptance.

## Privacy

The updater's only network use is the one feed request and, after consent, the two
asset downloads. It sends no file name, path, scan result, history, or preference.
There is no telemetry, no account, and no token. The daily check is a preference;
the menu item always works, and the app never downloads or installs without a click.
The release notes are publisher text in English and are shown as such, not passed
through the app's localization.

## UI (not yet implemented)

A sheet on the main window, with states:

`idle → checking → upToDate | available → downloading → ready → installing → done | failed`

- Available: current and new version, release notes in a scroll view, download size,
  the checksum/unsigned wording, Download, Later, Skip This Version.
- Downloading: real byte progress with Cancel.
- Ready: Install and Relaunch, with a warning that a scan in progress stops.
- Failed: a typed reason, retry where it helps, and the release page as a fallback.
- The menu item is "Check for Updates…" under About. Settings holds the daily-check
  toggle and the last check time; there is no second update window.
- Every string goes through `DiskLocalization`, with Arabic; the sheet gets a
  renderer screen so English, Arabic, and `en-XA` can be reviewed.
- The screen does not call an unsigned download verified or trusted. A green
  "verified" badge is not acceptable wording.

## Failure modes

| Failure | What the person sees | What changes |
|---|---|---|
| Offline / timeout | check again later | nothing |
| `404` (no release or not public) | no published release found | nothing |
| missing asset for this Mac | this release has no build for this Mac | nothing |
| missing `.sha256` | the release is incomplete | nothing |
| checksum mismatch | download did not match the published checksum | staged files deleted |
| extraction or bundle check fails | download is not a valid WillyDisk build | staged files deleted |
| not enough disk space | free space needed | nothing |
| not writable / translocated / read-only | move the app or download the zip | nothing |
| helper fails | previous copy is unchanged; open the log | backup restored |
| new build does not launch | the previous copy is in the update folder | manual restore |

## Testing

- `swift test --filter DiskUpdateTests` covers versions, feed decoding, asset
  selection, checksum parsing/hashing, and staged-bundle checks. The suite never
  touches the network: feed tests use a fake `FeedTransport`.
- A live check is a manual acceptance step against the public release, not a unit
  test. Do not add a test that downloads from GitHub.
- The install step needs a real update over a copy in `~/Applications`, then over
  `/Applications/WillyDisk.app`, including a checksum failure and a wrong-version
  failure. Then the TCC/Full Disk Access test above, and a Homebrew install/upgrade
  test once the cask declares `auto_updates`.
- Before a release, confirm the repository and the release assets are readable
  without credentials. A release that only the owner can download cannot update
  anyone.

## Open decisions

- **Homebrew:** self-update everywhere with `auto_updates true` (recommended), or
  defer to `brew upgrade` when a Caskroom receipt is present.
- **Signing:** accept the ad-hoc TCC cost and document it, or adopt a stable
  self-signed identity if updates otherwise lose Full Disk Access.
- **Automatic checks:** on by default with a daily request and a sheet (recommended),
  or manual-only from the menu.
- **Optional hardening:** Ed25519-signed archives, and a "Revert to Previous Version"
  action fed by the retained backup.
