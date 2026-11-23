#!/usr/bin/env bash
# SPDX-License-Identifier: MIT WITH Plumlang-trademarks
#
# The logic of plumlang/setup-plum, run by action.yml on Linux, macOS and
# Windows (Git Bash). It mirrors https://plum.elixpo.com/install.sh and
# install.ps1: the same asset names, archive layout, platform detection and
# SHA256SUMS check.
#
#   setup-plum.sh resolve   resolve PLUM_VERSION to an exact release
#   setup-plum.sh install   download, verify and unpack PLUM_VERSION into
#                           the runner tool cache, and put it on the PATH
#
# Settings, as environment variables:
#   PLUM_VERSION        latest, 2, 2.1, 2.1.4 or v2.1.4 (resolve); exact (install)
#   PLUM_TOKEN          a GitHub token for the releases API (optional)
#   PLUM_REUSE          true to reuse a finished install already in the tool cache
#   PLUM_DOWNLOAD_BASE  where releases are downloaded from (for mirrors)
#   PLUM_API            the GitHub API base URL
#
# Outputs go to $GITHUB_OUTPUT and the PATH to $GITHUB_PATH when they are set.
set -euo pipefail

REPO="plumlang/plumlang"
BASE="${PLUM_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download}"
API="${PLUM_API:-https://api.github.com}/repos/$REPO"

SCRATCH=""
trap 'if [ -n "$SCRATCH" ]; then rm -rf "$SCRATCH"; fi' EXIT
scratch() { # make SCRATCH a temporary directory, removed on exit
    SCRATCH="$(mktemp -d)"
}

say() { printf '%s\n' "$*"; }
fail() {
    printf '::error title=setup-plum::%s\n' "$*"
    printf 'setup-plum: %s\n' "$*" >&2
    exit 1
}

output() { # output <name> <value>
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
    fi
    say "$1=$2"
}

is_windows() {
    case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) return 0 ;; esac
    return 1
}

native_path() { # a path as the runner's tools expect it
    if is_windows && command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

unix_path() {
    if is_windows && command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "$1"; fi
}

fetch() { # fetch <url> <file>
    curl -fsSL --retry 3 --retry-delay 2 "$1" -o "$2"
}

api() { # api <path> <file>
    local args=(-fsSL --retry 3 --retry-delay 2 -H 'Accept: application/vnd.github+json'
        -H 'X-GitHub-Api-Version: 2022-11-28' -H 'User-Agent: setup-plum')
    if [ -n "${PLUM_TOKEN:-}" ]; then
        args+=(-H "Authorization: Bearer $PLUM_TOKEN")
    fi
    curl "${args[@]}" "$API$1" -o "$2"
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d ' ' -f 1
    else
        fail "needs sha256sum or shasum to check the download"
    fi
}

# The release asset for this machine, as install.sh and install.ps1 pick it.
detect_target() {
    local arch="${RUNNER_ARCH:-}"
    if [ -z "$arch" ]; then
        if is_windows; then
            arch="${PROCESSOR_ARCHITEW6432:-${PROCESSOR_ARCHITECTURE:-}}"
        else
            arch="$(uname -m)"
        fi
    fi
    case "$arch" in
        X64 | x64 | x86_64 | amd64 | AMD64) arch=x86_64 ;;
        ARM64 | arm64 | aarch64) arch=arm64 ;;
        riscv64) arch=riscv64 ;;
        *) fail "no Plumlang build for the $arch architecture" ;;
    esac
    case "$(uname -s)" in
        Linux)
            case "$arch" in
                x86_64 | arm64 | riscv64) target="linux-$arch" ;;
            esac
            ext=tar.gz
            ;;
        Darwin)
            target=macos-universal
            ext=tar.gz
            ;;
        MINGW* | MSYS* | CYGWIN*)
            case "$arch" in
                x86_64 | arm64) target="windows-$arch" ;;
                *) fail "no Plumlang build for Windows on $arch" ;;
            esac
            ext=zip
            ;;
        *) fail "no Plumlang build for $(uname -s)" ;;
    esac
}

# Pick the newest release matching a version prefix (empty for any) from the
# releases API's JSON, skipping drafts and prereleases.
newest_matching() { # newest_matching <prefix> <json files...>
    local prefix="$1"
    shift
    if command -v jq >/dev/null 2>&1; then
        jq -rs --arg p "$prefix" '
            [ .[][] | select(.draft | not) | select(.prerelease | not)
              | .tag_name | ltrimstr("v")
              | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
              | select($p == "" or . == $p or startswith($p + "."))
            ] | sort_by(split(".") | map(tonumber)) | last // empty' "$@"
    else
        local py
        py="$(command -v python3 || command -v python || true)"
        [ -n "$py" ] || fail "needs jq or python3 to read the releases API"
        "$py" -I -c '
import json, re, sys
p = sys.argv[1]
found = []
for name in sys.argv[2:]:
    with open(name, encoding="utf-8") as f:
        for r in json.load(f):
            if r.get("draft") or r.get("prerelease"):
                continue
            v = r["tag_name"].lstrip("v")
            if re.fullmatch(r"\d+\.\d+\.\d+", v) and (not p or v == p or v.startswith(p + ".")):
                found.append(tuple(int(x) for x in v.split(".")))
if found:
    print(".".join(map(str, max(found))))
' "$prefix" "$@"
    fi
}

resolve() {
    local want="${PLUM_VERSION:-latest}" tmp page version=""
    want="${want#v}"
    want="${want#V}"
    want="${want// /}"
    [ -n "$want" ] || want=latest

    if [[ "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+].+)?$ ]]; then
        version="$want" # exact: no API call; a missing release fails at download
    elif [ "$want" = latest ] || [[ "$want" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        [ "$want" = latest ] && want=""
        scratch
        tmp="$SCRATCH"
        for page in 1 2 3 4 5 6 7 8 9 10; do
            api "/releases?per_page=100&page=$page" "$tmp/releases-$page.json" ||
                fail "could not list the releases of $REPO (set the token input if the API rate limit was hit)"
            # An empty page is "[]"; stop there.
            if ! grep -q '"tag_name"' "$tmp/releases-$page.json"; then
                rm -f "$tmp/releases-$page.json"
                break
            fi
        done
        if compgen -G "$tmp/releases-*.json" >/dev/null; then
            version="$(newest_matching "$want" "$tmp"/releases-*.json)"
        fi
        [ -n "$version" ] || fail "no Plumlang release matches version '${PLUM_VERSION:-latest}'"
    else
        fail "version must be latest, a version like 2.1.4 or v2.1.4, or a prefix like 2.1 or 2; got '${PLUM_VERSION:-}'"
    fi

    detect_target
    say "Plumlang ${PLUM_VERSION:-latest} resolves to $version ($target)"
    output version "$version"
    output target "$target"
    output dir "$(native_path "$(tool_dir "$version")")"
}

tool_dir() { # where a version lives in the runner tool cache
    local root="${RUNNER_TOOL_CACHE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/toolcache}"
    printf '%s/plum/%s/%s\n' "$(unix_path "$root")" "$1" "$target"
}

extract_zip() { # extract_zip <zip> <dir>
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$1" -d "$2"
    else
        local ps
        ps="$(command -v pwsh || command -v powershell || true)"
        [ -n "$ps" ] || fail "needs unzip or PowerShell to unpack $(basename "$1")"
        "$ps" -NoProfile -NonInteractive -Command \
            "\$ErrorActionPreference = 'Stop'; \$ProgressPreference = 'SilentlyContinue'; Expand-Archive -LiteralPath '$(native_path "$1")' -DestinationPath '$(native_path "$2")'"
    fi
}

install() {
    local version="${PLUM_VERSION:-}" dir archive tmp want got exe
    version="${version#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+].+)?$ ]] ||
        fail "install needs an exact version, got '$version'"
    detect_target
    dir="$(tool_dir "$version")"
    exe=plum
    is_windows && exe=plum.exe

    if [ "${PLUM_REUSE:-true}" = true ] && [ -f "$dir.complete" ] && [ -x "$dir/$exe" ]; then
        say "Using Plumlang $version ($target) from $(native_path "$dir")"
    else
        archive="plum-$version-$target.$ext"
        scratch
        tmp="$SCRATCH"
        say "Downloading $archive"
        fetch "$BASE/v$version/$archive" "$tmp/$archive" ||
            fail "could not download $BASE/v$version/$archive (is $version a Plumlang release?)"
        fetch "$BASE/v$version/SHA256SUMS" "$tmp/SHA256SUMS" ||
            fail "could not download SHA256SUMS for $version"

        want="$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS" | tr -d '\r' | tr 'A-F' 'a-f')"
        [ -n "$want" ] || fail "SHA256SUMS has no entry for $archive"
        got="$(sha256 "$tmp/$archive")"
        if [ "$got" != "$want" ]; then
            fail "checksum mismatch for $archive: expected $want, got $got; nothing was installed"
        fi
        say "Checksum verified: $got"

        mkdir -p "$tmp/out"
        if [ "$ext" = zip ]; then
            extract_zip "$tmp/$archive" "$tmp/out"
        else
            tar -xzf "$tmp/$archive" -C "$tmp/out"
        fi
        [ -f "$tmp/out/plum-$version-$target/$exe" ] ||
            fail "$archive has no plum-$version-$target/$exe"

        rm -rf "$dir" "$dir.complete"
        mkdir -p "$(dirname "$dir")"
        mv "$tmp/out/plum-$version-$target" "$dir"
        chmod 755 "$dir/$exe"
        touch "$dir.complete"
    fi

    local reported
    reported="$("$dir/$exe" version 2>&1)" || fail "installed, but $dir/$exe does not run: $reported"
    case "$reported" in
        "plum $version "* | "plum $version") ;;
        *) fail "expected plum $version, but $exe reports: $reported" ;;
    esac

    if [ -n "${GITHUB_PATH:-}" ]; then
        native_path "$dir" >>"$GITHUB_PATH"
    fi
    output path "$(native_path "$dir")"
    say "Installed: $reported"
}

case "${1:-}" in
    resolve) resolve ;;
    install) install ;;
    *)
        say "usage: setup-plum.sh resolve|install" >&2
        exit 2
        ;;
esac
