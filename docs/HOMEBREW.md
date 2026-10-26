# Homebrew

WillyDisk installs with `brew install --cask` from this repository, which is its
own tap:

```
brew tap waelabdrabbo/willydisk https://github.com/waelabdrabbo/WillyDisk
brew trust --tap waelabdrabbo/willydisk
brew install --cask willydisk
```

A tap is a git repository that Homebrew clones and reads a `Casks/` or
`Formula/` directory from. `brew tap <owner>/<name>` alone assumes the remote is
GitHub's `<owner>/homebrew-<name>`; the two-argument form names any repository,
so the app's own repository can serve. Here it does.

## Why a tap and not `homebrew/cask`

[Acceptable Casks](https://docs.brew.sh/Acceptable-Casks) requires that an app
Homebrew distributes **passes Homebrew's Gatekeeper checks** on macOS. A build
passes only when it is signed with a Developer ID and notarized by Apple;
WillyDisk has no Apple Developer account, so every archive here is ad-hoc signed
and notarized by nobody. The [package acceptance
policy](https://docs.brew.sh/Package-Acceptance-Policy) also weighs how widely an
app is used, which a first release does not have yet.

So the cask lives in a tap this project owns. That is a normal Homebrew install
from a third-party tap, and it is not a Homebrew-reviewed package: Homebrew has
never looked at this app, and the cask says so in its caveats.

The unsigned status is the only thing standing between this tap and
`homebrew/cask`. With a Developer ID, signed and notarized archives, and a
review, the same cask could be submitted upstream.

## What the same-repo tap costs

- The tap line carries a URL, because one-argument `brew tap` only finds
  repositories named `homebrew-*`.
- Everyone who taps clones the whole project, not one Ruby file. It is a few
  megabytes and nothing is built from it.
- Each release commits `Casks/willydisk.rb` to `main` from CI. If `main` ever
  grows a branch protection rule that refuses pushes from `github-actions`,
  that commit fails and the release run stops; the fix is to allow the
  `github-actions` actor to push, or to commit the file by hand (see
  [Re-rendering by hand](#re-rendering-by-hand)).

A separate `homebrew-willydisk` repository would remove all three at the cost of
a second repository and a token to write it.

## The two cask files

| File | What it is |
|---|---|
| `.github/homebrew/willydisk.rb.tmpl` | the source: Ruby with four markers |
| `Casks/willydisk.rb` | the rendered cask Homebrew reads; written by a release, never edited |

The markers are `{{VERSION}}`, `{{SHA256_ARM64}}`, `{{SHA256_X86_64}}`, and
`{{REPOSITORY}}`, filled from `VERSION`, the two release archives' `.sha256`
files, and `GITHUB_REPOSITORY` (or `origin` when run locally).

A cask names one version and the checksum of each archive it downloads. Filling
those from the files `Scripts/package-release.sh` just wrote means a cask cannot
name a version whose archives do not exist — the failure that otherwise shows up
as `brew install` dying at the last step for every user.

## Rendering and checking

```
bash Scripts/homebrew-cask.sh render --assets .build/release --out Casks/willydisk.rb
bash Scripts/homebrew-cask.sh render --release v1.0.1   --out Casks/willydisk.rb
bash Scripts/homebrew-cask.sh render --arm64 <sha> --intel <sha> --out Casks/willydisk.rb
bash Scripts/homebrew-cask.sh check                    # template, and the committed cask
bash Scripts/homebrew-cask.sh check --audit            # plus Homebrew's own checks
```

`render` refuses to mix the two digest sources, and it verifies the rendered
result stanza by stanza before writing it. `check` renders the template with
placeholder digests — no build, no network — then reads `Casks/willydisk.rb`
when one exists. It deliberately does not compare that file's version with
`VERSION`: a bump must not fail before the release has re-rendered it.

`check --audit` runs `brew audit --cask --strict` and `brew style` over the
result. Homebrew refuses to audit a path, so the script places the cask in a
throwaway tap (`willydisk/homebrew-audit`), trusts it, audits it, then removes
the tap and the trust entry. CI runs this on every change
(`.github/workflows/ci.yml`, job `homebrew-cask`).

## The cask's stanzas

- `arch arm: "arm64", intel: "x86_64"` — the release ships one zip per
  architecture, not a universal binary, so the URL picks the slice and `sha256`
  carries one digest per architecture.
- `binary "#{appdir}/WillyDisk.app/Contents/MacOS/WillyDisk", target: "willydisk"`
  — the same executable dispatches the command line before SwiftUI loads, so
  Homebrew's `bin` link is the CLI, not a launcher.
- `depends_on macos: :sonoma` — macOS 14 is the deployment target
  (`platforms: [.macOS(.v14)]` in `Package.swift`).
- `uninstall quit:` and `zap trash:` name the bundle identifier
  `com.willydisk.app` and the two places the app writes state:
  `~/Library/Application Support/WillyDisk` (history and the reclaim log) and
  `~/Library/Preferences/com.willydisk.app.plist` (preferences).
- The caveats state the signing position. They are the only place a Homebrew
  user is told that Gatekeeper approval may be needed.

## Publishing on a release

`.github/workflows/release.yml` runs one new step, **Commit the cask the tap
serves**, between filling in the notes and publishing the release:

1. Clone `main` with the run's `GITHUB_TOKEN` — no personal token, no secret to
   configure.
2. Render `Casks/willydisk.rb` from `.build/release`, the same checksums this run
   built and verified.
3. Commit `willydisk <version>` and push, or exit quietly when the file is
   already current.

It runs *before* the release is published, so a run that cannot write the cask
stops with no release created, and re-running the job both fixes the cask and
publishes. If the cask commit lands and publishing then fails, the cask briefly
names a tag whose assets do not exist; re-running publishes them.

`permissions: contents: write` is already declared at the top of the workflow,
which is all the push needs.

## The first release in the tap

`v1.0.0` is **not** casked. Its archives predate the resource-bundle fix
described in `docs/ARCHITECTURE.md` §5: they look for their string catalog under
`WillyDisk.app/WillyDisk_DiskLocalization.bundle` and fall back to a path on the
build machine, so an installed copy crashes before it draws a window or prints a
report. The tap is empty until the first release that carries the fix.

Bump `VERSION`, tag `v<version>`, and the run writes the cask. Until that has
happened, `brew tap` succeeds and reports no casks.

## Re-rendering by hand

If a run cannot push, or the tap needs a version before the workflow exists:

```
bash Scripts/homebrew-cask.sh render --release v<version> --out Casks/willydisk.rb
bash Scripts/homebrew-cask.sh check --audit
git add Casks/willydisk.rb && git commit -m "willydisk <version>" && git push
```

`render --release` reads the published `.sha256` files, so it works only once
the repository is public; the checksums have to be the published ones, not a
local rebuild's. Install that tag's archive once before committing: a cask is
only as good as the build it points at.

## What the user gets

- `brew install --cask willydisk` puts `WillyDisk.app` in `/Applications` and
  links `willydisk` into `$(brew --prefix)/bin`.
- `brew upgrade --cask willydisk` — the app has no self-updater, so this is the
  only way updates arrive. The cask carries a `livecheck` pointed at the
  repository's releases, so `brew livecheck --cask willydisk` follows the tag
  stream as well as `brew upgrade` does.
- `brew uninstall --cask willydisk` removes the app and the `bin` link;
  `--zap` also removes the history and preferences listed above.
- **Trust.** Current Homebrew versions refuse to load a cask from a
  non-official tap until it is trusted, which is why the install sequence starts
  with `brew trust --tap …`. The trust is recorded in
  `~/.homebrew/trust.json`, not in this repository.
- **Gatekeeper.** `brew install --cask` quarantines the bundle, so macOS blocks
  the first launch until the app is approved once. The block covers the linked
  command too: `willydisk` is killed on start, because it is the same
  quarantined executable. Approving the app in System Settings → Privacy &
  Security → Open Anyway clears it, as does
  `xattr -dr com.apple.quarantine /Applications/WillyDisk.app`; the caveats
  print both the fact and the command. A download straight from the Releases
  page behaves the same way. Full Disk Access stays optional.

## Changing the cask

Edit `.github/homebrew/willydisk.rb.tmpl`, then run
`bash Scripts/homebrew-cask.sh check --audit`. Do not edit `Casks/willydisk.rb`:
the next release overwrites it, and the diff is the only signal that the template
changed.
