# DiskUpdate — agent notes

The release feed and the checks an update must pass before it can replace the
installed app. Foundation and CryptoKit only: no SwiftUI, AppKit, DiskCore, or
DiskLocalization. Failures are typed (`UpdateError`); the sentences a person reads
belong in DiskUI's catalog.

| File | What it holds |
|---|---|
| `ReleaseVersion.swift` | One-to-three-number versions; `1.0.10` is newer than `1.0.9` |
| `UpdateRelease.swift` | Release and asset values, asset naming, `UpdateEvaluator` |
| `ReleaseFeed.swift` | `FeedTransport` seam, `URLSession` transport, GitHub `releases/latest`, ETag |
| `Checksum.swift` | `SHA256Digest`, `.sha256` parsing, streaming file hash |
| `UpdateVerifier.swift` | Checksum check, `ditto` extraction, bundle/architecture/signature validation |
| `InstalledBuild.swift` | The running bundle's version, identifier, architecture, macOS |

Rules:

- The feed is one unauthenticated GET to `api.github.com`; the only other requests
  are the two release assets the person consented to download. No scan data, paths,
  or file names ever leave the Mac. Do not add a token.
- Asset lookup is by exact name, built from the release's **marketing** version
  (`WillyDisk-<version>-<arch>.zip` and `.sha256`), never by guessing from a URL.
- A release is only usable when both assets exist for this Mac and the tag is
  `v<version>`. Missing files are `noBuildForThisMac` / `incompleteRelease`, not a
  download error.
- The verifier's methods are synchronous filesystem or `Process` work; the feed is
  async network. Callers run the blocking parts off the main actor; never make a
  controller do this on the main thread.
- Never execute the downloaded app. The checksum, bundle identity, architecture,
  and `codesign --verify` are the checks; the release pipeline is what runs it.
- Comments are evergreen: no task numbers, no narration of what changed.

Tests: `swift test --filter DiskUpdateTests`. The feed tests use a fake
`FeedTransport`; nothing in the suite needs a network. Do not add a test that
downloads from GitHub.
