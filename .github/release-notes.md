WillyDisk {{VERSION}}, built from the `{{TAG}}` tag. Requires macOS 14 or later.

**These builds are unsigned and not notarized.** macOS will refuse one the first
time you open it. WillyDisk has no Apple Developer account, so no Gatekeeper
approval is claimed or implied. The checksums below detect a corrupted or
altered download; they are not proof that the build is trustworthy.

## Which download

- **Apple Silicon:** `WillyDisk-{{VERSION}}-arm64.zip`
- **Intel:** `WillyDisk-{{VERSION}}-x86_64.zip`

`uname -m` prints `arm64` or `x86_64` if you are not sure which Mac you have.

## Install

1. Download the zip for your Mac and its `.sha256` file into the same folder,
   then check the download:

   ```
   shasum -a 256 -c WillyDisk-{{VERSION}}-arm64.zip.sha256   # Apple Silicon
   shasum -a 256 -c WillyDisk-{{VERSION}}-x86_64.zip.sha256  # Intel
   ```

2. Unzip the archive and move `WillyDisk.app` to `/Applications`.

3. Open the app once. macOS blocks it; approve it in System Settings →
   Privacy & Security → Open Anyway. (Control-click → Open is not offered on
   macOS 15 and later.) Or remove the download flag first and open it again:

   ```
   xattr -dr com.apple.quarantine /Applications/WillyDisk.app
   ```

4. Full Disk Access is optional. Without it the app measures what it can read
   and reports what it could not; grant it in System Settings → Privacy &
   Security when you want the whole disk measured.

SHA-256, Apple Silicon: `{{SHA256_ARM64}}`

SHA-256, Intel: `{{SHA256_X86_64}}`

## Build from source

A build from your own checkout carries no quarantine flag, so there is no
approval step:

```
git clone {{REPO_URL}}
cd WillyDisk
bash Scripts/run.sh
```

See the [README]({{REPO_LINK}}#build-and-run) for the toolchain requirement
and the other scripts.
