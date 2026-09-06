#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043  # `local` — supported by every shell this project targets
# shellcheck disable=SC1091  # the script under test is sourced by path
# shellcheck disable=SC2034  # NB_* variables are consumed by the sourced script, not by this file
# Upstream compatibility check — needs network. Verifies that the assumptions netbird.sh makes
# about the NetBird release layout still hold:
#   · the releases API still parses into "<tag> <prerelease> <draft>"
#   · every architecture in the support matrix still has a linux asset in the latest release
#   · GitHub still publishes a per-asset sha256 digest
#   · one real asset downloads and matches that digest
# Set NB_GITHUB_TOKEN to avoid the 60-requests-per-hour anonymous limit in CI.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)

FAIL=0
PASS=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

NB_SOURCE_ONLY=1
export NB_SOURCE_ONLY
# shellcheck source=../netbird.sh
. "${SCRIPT_DIR}/netbird.sh"

NB_CACHE_TTL=0        # always hit the API; a cached copy would defeat the point of this test

printf '\n== release API ==\n'
JSON=$(_cached_releases) || { printf '  FAIL could not reach the releases API\n'; exit 1; }
LIST=$(printf '%s' "$JSON" | _parse_releases | awk '$3 == "false"')
if [ -n "$LIST" ]; then ok "releases parsed ($(printf '%s\n' "$LIST" | wc -l | tr -d ' ') entries)"
else bad "releases parsed"; exit 1; fi

LATEST=$(printf '%s\n' "$LIST" | awk '$2 == "false" {print $1; exit}')
if is_valid_version_tag "$LATEST"; then ok "latest stable tag looks sane: $LATEST"
else bad "latest stable tag: '$LATEST'"; exit 1; fi

printf '\n== asset matrix for %s ==\n' "$LATEST"
ARCHES="amd64 arm64 armv6 386 mips_hardfloat mips_softfloat mipsle_hardfloat mipsle_softfloat"
ARCHES="$ARCHES mips64_hardfloat mips64_softfloat mips64le_hardfloat mips64le_softfloat"

REL=$(_gh_api "${NB_GITHUB_DIGEST_API}/repos/${NB_REPO}/releases/tags/${LATEST}")
if [ -z "$REL" ]; then printf '  FAIL could not fetch release %s\n' "$LATEST"; exit 1; fi
REL_LINES=$(printf '%s' "$REL" | _json_lines)

SMALLEST_ASSET=""
for a in $ARCHES; do
    name=$(asset_name "$LATEST" "$a")
    if printf '%s\n' "$REL_LINES" | grep -qxF "\"name\":\"${name}\""; then
        digest=$(_release_sha256 "$LATEST" "$name")
        if [ "${#digest}" -eq 64 ]; then
            ok "$a — asset present, digest published"
            [ "$a" = "386" ] && SMALLEST_ASSET="$name"
        else
            bad "$a — asset present but no sha256 digest"
        fi
    else
        bad "$a — no asset named $name"
    fi
done

printf '\n== real download + verify ==\n'
[ -n "$SMALLEST_ASSET" ] || SMALLEST_ASSET=$(asset_name "$LATEST" amd64)
mkdir -p "$TMP_DIR" || exit 1
URL="https://github.com/${NB_REPO}/releases/download/${LATEST}/${SMALLEST_ASSET}"
OUT="${TMP_DIR}/${SMALLEST_ASSET}"
if curl -fL --connect-timeout 15 --max-time 600 -o "$OUT" "$URL" 2>/dev/null; then
    ok "downloaded $SMALLEST_ASSET"
    EXPECT=$(_release_sha256 "$LATEST" "$SMALLEST_ASSET")
    if _verify_sha256 "$OUT" "$EXPECT" > /dev/null 2>&1; then ok "sha256 matches the published digest"
    else bad "sha256 mismatch"; fi
    if tar -tzf "$OUT" 2>/dev/null | grep -qx 'netbird'; then ok "archive contains a top-level 'netbird' binary"
    else bad "archive layout changed — no top-level 'netbird' entry"; fi
else
    bad "could not download $SMALLEST_ASSET"
fi

printf '\n== summary ==\n'
printf '  %s passed, %s failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
