#!/usr/bin/env bash
#
# release.sh — cut a release: bump VERSION, push it, wait for CI, tag, publish.
#
# Usage:   bash Scripts/release.sh <version>             # the whole release
#          bash Scripts/release.sh <version> --no-wait   # tag without the CI gate
#          bash Scripts/release.sh <version> --tag-only  # the bump is already pushed
#          bash Scripts/release.sh <version> --dry-run   # print the plan, change nothing
#
# Publishing is a `v*` tag push and nothing else. `ci.yml` builds every push to
# main but publishes nothing; `release.yml` refuses a tag that does not name the
# version in VERSION. So the bump is pushed and accepted by CI first, and the tag
# lands on that commit.
#
# A tag is never moved: `release.yml` publishes a version once and then refuses
# to rewrite it. A version that already has a tag, here or on the remote, is
# refused for the same reason. `--tag-only` completes a release whose bump is
# already pushed — the way out of a CI failure on an earlier run.
#
# The CI gate reads the public Actions API through curl and python3, so it needs
# no token and no `gh` install; it polls about once a minute for up to 35.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

VERSION_FILE="$ROOT_DIR/VERSION"
REMOTE="origin"
BRANCH="main"

usage() {
    cat >&2 <<'EOF'
usage: bash Scripts/release.sh <version> [--no-wait] [--tag-only] [--dry-run]

  <version>    the version to release, like 1.0.2 (a leading "v" is accepted)
  --no-wait    tag without waiting for the CI run on the bump commit
  --tag-only   VERSION is already bumped and pushed; only tag and publish it
  --dry-run    print every step, change nothing, push nothing
EOF
    exit "${1:-1}"
}

die() {
    echo "error: $*" >&2
    exit 1
}

say() {
    printf '%s\n' "$*"
}

# Component-wise, so 1.0.10 is newer than 1.0.9 and 1.0 is 1.0.0.
version_gt() {
    local left="$1" right="$2" i l r
    local -a a b
    IFS=. read -r -a a <<< "$left"
    IFS=. read -r -a b <<< "$right"
    for i in 0 1 2; do
        l="${a[$i]:-0}"
        r="${b[$i]:-0}"
        if (( 10#$l != 10#$r )); then
            if (( 10#$l > 10#$r )); then
                return 0
            fi
            return 1
        fi
    done
    return 1
}

# The repository slug the Actions API is read from. CI sets GITHUB_REPOSITORY; a
# local run reads it from origin, so no owner is hardcoded here. Fails quietly:
# the caller decides whether an unknown repository is fatal.
repository_slug() {
    local slug="${GITHUB_REPOSITORY:-}" url
    if [ -z "$slug" ]; then
        url="$(git -C "$ROOT_DIR" remote get-url "$REMOTE" 2>/dev/null || true)"
        case "$url" in
            https://github.com/*)   slug="${url#https://github.com/}" ;;
            git@github.com:*)       slug="${url#git@github.com:}" ;;
            ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
        esac
        slug="${slug%.git}"
    fi
    [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
    printf '%s\n' "$slug"
}

# Prints "<status> <conclusion>" for the newest CI run on a commit, and nothing
# when GitHub has not listed one yet. A cancelled run counts as a failure, which
# is why the conclusion is read and not just the status.
ci_state() {
    local sha="$1" payload
    payload="$(curl -sS -m 20 \
        "https://api.github.com/repos/$SLUG/actions/runs?head_sha=$sha&per_page=1")" || return 3
    printf '%s' "$payload" | python3 -c '
import json, sys
data = json.load(sys.stdin)
if "workflow_runs" not in data:
    print(data.get("message", "the API refused the request"), file=sys.stderr)
    sys.exit(2)
runs = data["workflow_runs"]
if runs:
    print(runs[0]["status"], runs[0]["conclusion"] or "")
'
}

MODE="release"
WAIT=1
DRY_RUN=0
VERSION_ARG=""

for arg in "$@"; do
    case "$arg" in
        --no-wait)  WAIT=0 ;;
        --tag-only) MODE="tag-only" ;;
        --dry-run)  DRY_RUN=1 ;;
        -h|--help)  usage 0 ;;
        -*)         die "unknown option '$arg'." ;;
        *)
            if [ -n "$VERSION_ARG" ]; then
                die "one version per run, not '$VERSION_ARG' and '$arg'."
            fi
            VERSION_ARG="$arg"
            ;;
    esac
done

[ -n "$VERSION_ARG" ] || usage
VERSION_ARG="${VERSION_ARG#v}"
if ! [[ "$VERSION_ARG" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    die "the version must be one to three period-separated numbers, like 1.0.2, not '$VERSION_ARG'."
fi
TAG="v$VERSION_ARG"

[ -f "$VERSION_FILE" ] || die "missing the version source at $VERSION_FILE."
CURRENT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if ! [[ "$CURRENT_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    die "VERSION must be one to three period-separated numbers, not '$CURRENT_VERSION'."
fi

if [ "$MODE" = "release" ]; then
    if [ "$CURRENT_VERSION" = "$VERSION_ARG" ]; then
        die "VERSION already says $VERSION_ARG; pass the next version, or --tag-only to tag this one."
    fi
    version_gt "$VERSION_ARG" "$CURRENT_VERSION" ||
        die "VERSION is $CURRENT_VERSION; a release moves it forward, and $VERSION_ARG is not newer."
else
    if [ "$CURRENT_VERSION" != "$VERSION_ARG" ]; then
        die "--tag-only releases $VERSION_ARG, but VERSION says $CURRENT_VERSION."
    fi
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    die "tag $TAG already exists here; a published version is never re-tagged. Use a new version."
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree."
git remote get-url "$REMOTE" >/dev/null 2>&1 || die "there is no '$REMOTE' remote to push to."

git fetch --quiet "$REMOTE" "$BRANCH" ||
    die "could not fetch $REMOTE/$BRANCH; check the network and the remote."

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
    die "on '$CURRENT_BRANCH', not '$BRANCH'; a release is cut from $BRANCH."
fi

HEAD_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse "$REMOTE/$BRANCH")"
if [ "$HEAD_SHA" != "$REMOTE_SHA" ]; then
    die "$BRANCH has local commits $REMOTE/$BRANCH does not, or the other way around; pull or push first."
fi

# A release commit carries the version bump alone. Untracked scratch files are
# none of this script's business.
if [ "$MODE" = "release" ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    git status --short --untracked-files=no >&2
    die "the working tree has uncommitted changes; a release commit carries the version bump alone."
fi

# The tag names the version in the commit it points at, which is what
# release.yml checks, so an uncommitted bump here would tag the wrong version.
if [ "$MODE" = "tag-only" ]; then
    HEAD_VERSION="$(git show "HEAD:VERSION" 2>/dev/null | tr -d '[:space:]')"
    if [ "$HEAD_VERSION" != "$VERSION_ARG" ]; then
        die "HEAD's VERSION is '${HEAD_VERSION:-missing}', not $VERSION_ARG; commit the bump before tagging."
    fi
fi

REMOTE_TAG="$(git ls-remote --tags "$REMOTE" "refs/tags/$TAG")" ||
    die "could not read the tags on $REMOTE; refusing to tag without checking that $TAG is free."
if [ -n "$REMOTE_TAG" ]; then
    die "$REMOTE already has a $TAG tag; a published version is never re-tagged. Use a new version."
fi

if command -v gh >/dev/null 2>&1 && gh release view "$TAG" >/dev/null 2>&1; then
    die "GitHub already has a release for $TAG; bump VERSION and tag a new version."
fi

# Checked before anything is pushed: a release that cannot be watched must fail
# while the tree is still untouched, not after the bump is public.
if [ "$DRY_RUN" -eq 0 ] && [ "$WAIT" -eq 1 ]; then
    command -v curl >/dev/null 2>&1 || die "the CI gate needs curl; or pass --no-wait."
    command -v python3 >/dev/null 2>&1 || die "the CI gate needs python3; or pass --no-wait."
    SLUG="$(repository_slug)" ||
        die "cannot tell which GitHub repository this is; set GITHUB_REPOSITORY to owner/name."
fi

if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$MODE" = "release" ]; then
        say "Would release $VERSION_ARG (VERSION $CURRENT_VERSION → $VERSION_ARG):"
        say "  1. commit VERSION as \"chore(release): $VERSION_ARG\""
        say "  2. push $BRANCH to $REMOTE"
        if [ "$WAIT" -eq 1 ]; then
            say "  3. wait for CI on the new commit, and stop if it fails"
        else
            say "  3. skip the CI gate (--no-wait)"
        fi
        say "  4. tag $TAG at that commit and push it, which publishes the release"
    else
        say "Would tag $TAG at $HEAD_SHA without a commit:"
        say "  1. confirm VERSION already says $VERSION_ARG, which it does"
        if [ "$WAIT" -eq 1 ]; then
            say "  2. wait for CI on $HEAD_SHA, and stop if it fails"
        else
            say "  2. skip the CI gate (--no-wait)"
        fi
        say "  3. tag $TAG and push it, which publishes the release"
    fi
    exit 0
fi

if [ "$MODE" = "release" ]; then
    printf '%s\n' "$VERSION_ARG" > "$VERSION_FILE"
    git add "$VERSION_FILE"
    git commit --quiet -m "chore(release): $VERSION_ARG"
    say "Committed the version bump to $VERSION_ARG."

    git push --quiet "$REMOTE" "$BRANCH" ||
        die "could not push $BRANCH; the bump is committed but not published."
    say "Pushed $BRANCH. CI is building it now."
fi

HEAD_SHA="$(git rev-parse HEAD)"

if [ "$WAIT" -eq 1 ]; then
    say "Waiting for CI on $HEAD_SHA (build, suite, renders, cask audit); about a minute between checks…"
    STATUS=""
    CONCLUSION=""
    EMPTY=0
    for _ in $(seq 1 35); do
        if ! STATE="$(ci_state "$HEAD_SHA")"; then
            die "could not read the CI run for $HEAD_SHA; the repository may be private or the API rate-limited. Pass --no-wait to tag without the gate."
        fi
        if [ -z "$STATE" ]; then
            EMPTY=$((EMPTY + 1))
            if [ "$EMPTY" -ge 5 ]; then
                die "no CI run appeared for $HEAD_SHA after five minutes; check Actions, then pass --tag-only."
            fi
        else
            EMPTY=0
            read -r STATUS CONCLUSION <<< "$STATE"
            if [ "$STATUS" = "completed" ]; then
                break
            fi
            say "  CI is $STATUS."
        fi
        sleep 60
    done

    [ "$STATUS" = "completed" ] ||
        die "CI did not finish for $HEAD_SHA within 35 minutes; check Actions, then pass --tag-only."
    if [ "$CONCLUSION" != "success" ]; then
        die "CI concluded '${CONCLUSION}' for $HEAD_SHA. Fix it, push, then run this script again with --tag-only."
    fi
    say "CI passed."
fi

git tag -a "$TAG" -m "WillyDisk $VERSION_ARG" ||
    die "could not create $TAG; check user.name and user.email, then run again with --tag-only."
say "Tagged $TAG at $(git rev-parse --short HEAD)."

git push --quiet "$REMOTE" "$TAG" ||
    die "could not push $TAG; it is tagged locally, so delete it (git tag -d $TAG) and re-run with --tag-only."

say ""
say "Pushed $TAG. The Release workflow is packaging arm64 and x86_64 now."
if [ -z "${SLUG:-}" ]; then
    SLUG="$(repository_slug 2>/dev/null || true)"
fi
if [ -n "$SLUG" ]; then
    say "Watch it:  https://github.com/$SLUG/actions/workflows/release.yml"
else
    say "Watch the Release workflow on the repository's Actions tab."
fi
say "Then pull before your next push: the release commits Casks/willydisk.rb to $BRANCH itself."
