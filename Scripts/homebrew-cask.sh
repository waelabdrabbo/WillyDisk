#!/usr/bin/env bash
#
# homebrew-cask.sh — render the Homebrew cask that the tap serves.
#
# Usage:   bash Scripts/homebrew-cask.sh render --assets .build/release --out <file>
#          bash Scripts/homebrew-cask.sh render --release v1.0.0   --out <file>
#          bash Scripts/homebrew-cask.sh render --arm64 <sha256> --intel <sha256> --out <file>
#          bash Scripts/homebrew-cask.sh check [--audit]
#
# The cask has two files: the template at .github/homebrew/willydisk.rb.tmpl, and
# the rendered copy at Casks/willydisk.rb that Homebrew reads. This repository is
# its own tap — `brew tap <owner>/willydisk <repo url>` — so Casks/ is what a
# tapper clones; the version and digests in it are filled from VERSION and the
# release archives, and a cask can therefore never name a version no release
# published.
#
# render writes the rendered cask to --out, or to stdout when --out is omitted.
# Digests come from a directory of release checksums (--assets), from the GitHub
# release itself (--release), or from the command line. Exactly one must be used,
# because a cask that mixes a filename's checksum with another build's is the
# one failure this script exists to prevent.
#
# check renders with placeholder digests and asserts the template still produces
# the stanzas the tap needs, then reads the committed Casks/willydisk.rb when one
# exists. --audit additionally runs Homebrew's audit and style checks over the
# result in a throwaway tap, which needs Homebrew and a network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

TEMPLATE="$ROOT_DIR/.github/homebrew/willydisk.rb.tmpl"
VERSION_FILE="$ROOT_DIR/VERSION"

usage() {
    sed -n '5,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 1
}

die() {
    echo "error: $*" >&2
    exit 1
}

if [ ! -f "$TEMPLATE" ]; then
    die "missing the cask template at $TEMPLATE."
fi

APP_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if ! [[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    die "VERSION must be one to three period-separated numbers, not '$APP_VERSION'."
fi

# The repository slug the cask's URLs point at. CI sets GITHUB_REPOSITORY; a
# local run reads it from origin, so no owner is hardcoded in the template.
repository_slug() {
    local slug="${GITHUB_REPOSITORY:-}"
    if [ -z "$slug" ]; then
        local url
        url="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
        case "$url" in
            https://github.com/*) slug="${url#https://github.com/}" ;;
            git@github.com:*)     slug="${url#git@github.com:}" ;;
            ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
        esac
        slug="${slug%.git}"
    fi
    if ! [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        die "cannot tell which GitHub repository this is; set GITHUB_REPOSITORY to owner/name."
    fi
    printf '%s\n' "$slug"
}

valid_digest() {
    [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

# Reads a cask directory of .sha256 files: the first field of the file named for
# an architecture is that archive's digest.
digest_from_assets() {
    local dir="$1" arch="$2" file digest
    file="$dir/WillyDisk-$APP_VERSION-$arch.zip.sha256"
    if [ ! -f "$file" ]; then
        die "missing $file; run Scripts/package-release.sh first or pass --release."
    fi
    digest="$(awk 'NR == 1 {print $1}' "$file")"
    if ! valid_digest "$digest"; then
        die "$file does not hold a SHA-256 digest."
    fi
    printf '%s\n' "$digest"
}

# Reads the published checksum file from the release, so a cask can be rendered
# for a tag that was released before this script existed.
digest_from_release() {
    local tag="$1" arch="$2" url digest
    url="https://github.com/$REPOSITORY/releases/download/$tag/WillyDisk-$APP_VERSION-$arch.zip.sha256"
    digest="$(curl -fsSL --max-time 60 "$url" | awk 'NR == 1 {print $1}')" || {
        die "could not download $url; the tag and the release assets must exist first."
    }
    if ! valid_digest "$digest"; then
        die "$url did not return a SHA-256 digest."
    fi
    printf '%s\n' "$digest"
}

# Substitutes the four markers. Everything else in the template is Ruby and is
# copied verbatim.
render_template() {
    local arm64="$1" intel="$2" out="$3" tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/willydisk-cask.XXXXXX")"
    sed \
        -e "s|{{VERSION}}|$APP_VERSION|g" \
        -e "s|{{SHA256_ARM64}}|$arm64|g" \
        -e "s|{{SHA256_X86_64}}|$intel|g" \
        -e "s|{{REPOSITORY}}|$REPOSITORY|g" \
        "$TEMPLATE" > "$tmp"
    if grep -q '{{' "$tmp"; then
        echo "error: the rendered cask still carries an unfilled marker:" >&2
        grep -n '{{' "$tmp" >&2
        rm -f "$tmp"
        exit 1
    fi
    mv "$tmp" "$out"
}

# Guards the stanzas the tap depends on. A template edit that drops one of them
# is caught here rather than by the cask failing on a user's Mac.
verify_rendered() {
    local file="$1" arm64="$2" intel="$3" expected
    local checks=(
        'cask "willydisk" do'
        'arch arm: "arm64", intel: "x86_64"'
        "version \"$APP_VERSION\""
        "sha256 arm:   \"$arm64\","
        "intel: \"$intel\""
        "url \"https://github.com/$REPOSITORY/releases/download/v#{version}/WillyDisk-#{version}-#{arch}.zip\""
        'name "WillyDisk"'
        'homepage "https://github.com/'"$REPOSITORY"'"'
        'depends_on macos: :sonoma'
        'app "WillyDisk.app"'
        'binary "#{appdir}/WillyDisk.app/Contents/MacOS/WillyDisk", target: "willydisk"'
        'uninstall quit: "com.willydisk.app"'
        'caveats'
        'zap trash: ['
    )
    for expected in "${checks[@]}"; do
        if ! grep -qF -- "$expected" "$file"; then
            die "the rendered cask is missing '$expected'."
        fi
    done
    if ! valid_digest "$arm64" || ! valid_digest "$intel"; then
        die "a digest is not 64 lowercase hexadecimal characters."
    fi
    if [ "$arm64" = "$intel" ]; then
        die "the arm64 and x86_64 archives share a digest; one of them is the wrong file."
    fi
}

# The committed copy is what Homebrew reads, so it must still be a rendered cask
# rather than a half-edited one. It may name an older version than VERSION: a
# version bump must not fail before the release has re-rendered it.
verify_committed_cask() {
    local file="$1" digests count
    if grep -q '{{' "$file"; then
        die "$file still carries a template marker; it is generated, never edited."
    fi
    if ! grep -qF 'cask "willydisk" do' "$file"; then
        die "$file does not open the willydisk cask."
    fi
    if ! grep -qE '^  version "[0-9]+(\.[0-9]+){0,2}"$' "$file"; then
        die "$file has no plain version line."
    fi
    digests="$(grep -oE '[0-9a-f]{64}' "$file" | sort -u)"
    count="$(printf '%s\n' "$digests" | wc -l | tr -d ' ')"
    if [ "$count" -ne 2 ]; then
        die "$file should carry one digest per architecture; found $count."
    fi
    grep -qF 'app "WillyDisk.app"' "$file" || die "$file does not install WillyDisk.app."
    grep -qF 'target: "willydisk"' "$file" || die "$file does not link the willydisk command."
}

# Homebrew refuses to audit a file path, so the rendered cask is placed in a
# throwaway tap, audited as `<tap>/willydisk`, and the tap is removed again.
audit_rendered() {
    local file="$1" tap="willydisk/homebrew-audit" dir status=0
    if ! command -v brew >/dev/null 2>&1; then
        die "--audit needs Homebrew on PATH."
    fi
    dir="$(brew --repository)/Library/Taps/$tap"
    if [ -e "$dir" ]; then
        die "a tap already exists at $dir; remove it (brew untap $tap) before auditing."
    fi
    echo "Auditing the rendered cask with Homebrew…"
    brew tap-new --no-git "$tap" >/dev/null
    mkdir -p "$dir/Casks"
    cp "$file" "$dir/Casks/willydisk.rb"
    # Current Homebrew versions load a non-official tap's cask only once the tap
    # is trusted; older ones have no such step and ignore this.
    brew trust --tap "$tap" >/dev/null 2>&1 || true
    brew audit --cask --strict "willydisk/homebrew-audit/willydisk" || status=1
    brew style "$dir/Casks/willydisk.rb" || status=1
    brew untrust --tap "$tap" >/dev/null 2>&1 || true
    brew untap "$tap" >/dev/null 2>&1 || true
    return "$status"
}

command="${1:-}"
[ -n "$command" ] || usage
shift

REPOSITORY="$(repository_slug)"

case "$command" in
    render)
        assets="" release="" arm64="" intel="" out=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --assets)  [ "$#" -ge 2 ] || usage; assets="$2"; shift 2 ;;
                --release) [ "$#" -ge 2 ] || usage; release="$2"; shift 2 ;;
                --arm64)   [ "$#" -ge 2 ] || usage; arm64="$2"; shift 2 ;;
                --intel)   [ "$#" -ge 2 ] || usage; intel="$2"; shift 2 ;;
                --out)     [ "$#" -ge 2 ] || usage; out="$2"; shift 2 ;;
                *) usage ;;
            esac
        done

        sources=0
        [ -n "$assets" ] && sources=$((sources + 1))
        [ -n "$release" ] && sources=$((sources + 1))
        { [ -n "$arm64" ] || [ -n "$intel" ]; } && sources=$((sources + 1))
        if [ "$sources" -ne 1 ]; then
            die "pass exactly one digest source: --assets, --release, or --arm64 and --intel."
        fi

        if [ -n "$assets" ]; then
            [ -d "$assets" ] || die "no such directory: $assets"
            arm64="$(digest_from_assets "$assets" arm64)"
            intel="$(digest_from_assets "$assets" x86_64)"
        elif [ -n "$release" ]; then
            if [ "$release" != "v$APP_VERSION" ]; then
                die "--release '$release' does not match VERSION $APP_VERSION; a cask may only name a release that carries this version."
            fi
            arm64="$(digest_from_release "$release" arm64)"
            intel="$(digest_from_release "$release" x86_64)"
        else
            [ -n "$arm64" ] && [ -n "$intel" ] || die "pass both --arm64 and --intel, or use --assets/--release."
        fi

        if [ -n "$out" ]; then
            mkdir -p "$(dirname "$out")"
            render_template "$arm64" "$intel" "$out"
            verify_rendered "$out" "$arm64" "$intel"
            echo "Rendered $out for WillyDisk $APP_VERSION ($REPOSITORY)."
            echo "  arm64  $arm64"
            echo "  x86_64 $intel"
        else
            tmp="$(mktemp "${TMPDIR:-/tmp}/willydisk-cask.XXXXXX")"
            trap 'rm -f "$tmp"' EXIT
            render_template "$arm64" "$intel" "$tmp"
            verify_rendered "$tmp" "$arm64" "$intel"
            cat "$tmp"
        fi
        ;;

    check)
        audit=0
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --audit) audit=1; shift ;;
                *) usage ;;
            esac
        done

        tmp="$(mktemp "${TMPDIR:-/tmp}/willydisk-cask.XXXXXX")"
        trap 'rm -f "$tmp"' EXIT
        # Placeholder digests: the structure is what this checks, and a real
        # digest for an unreleased version cannot exist here.
        arm64="$(printf 'a%.0s' {1..64})"
        intel="$(printf 'b%.0s' {1..64})"
        render_template "$arm64" "$intel" "$tmp"
        verify_rendered "$tmp" "$arm64" "$intel"
        echo "The cask template renders for WillyDisk $APP_VERSION ($REPOSITORY)."
        if [ -f "$ROOT_DIR/Casks/willydisk.rb" ]; then
            verify_committed_cask "$ROOT_DIR/Casks/willydisk.rb"
            echo "The committed Casks/willydisk.rb is a rendered cask."
        else
            echo "No Casks/willydisk.rb yet; the next release writes it."
        fi
        if [ "$audit" -eq 1 ]; then
            audit_rendered "$tmp"
        fi
        ;;

    *)
        usage
        ;;
esac
