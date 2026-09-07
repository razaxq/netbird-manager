#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC1091,SC2034  # sourced manager consumes the isolated configuration
# Opt-in integration test for an ephemeral Linux CI runner. No setup key or login.
set -eu
[ "${NB_CI_SYSTEMD_TEST:-0}" = 1 ] || { printf 'CI opt-in required\n' >&2; exit 2; }
[ "$(id -u)" = 0 ] && [ -d /run/systemd/system ] || exit 2
[ -x "${NB_TEST_REAL_BIN:-}" ] || exit 2
SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
NB_SOURCE_ONLY=1
NB_NONINTERACTIVE=1
NB_BIN_DIR="$T/bin"
NB_ETC_DIR="$T/etc"
NB_CONFIG_FILE="$T/profile.json"
NB_DAEMON_ADDR="unix://$T/first.sock"
NB_LOG_FILE=console
LOG_FILE="$T/manager.log"
# shellcheck source=../netbird.sh
. "$SCRIPT_DIR/netbird.sh"
INIT_SYS=systemd
NB_SERVICE_NAME="netbird-manager-ci-$$"
unit=$(svc_file_path)
cleanup_ci() {
    systemctl stop "$NB_SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$NB_SERVICE_NAME" 2>/dev/null || true
    rm -f "$unit"
    systemctl daemon-reload
    _cleanup
    rm -rf "$T"
}
trap 'cleanup_ci' EXIT
# Exercise the complete install flow using the asset already verified by CI.
# No setup key is supplied: installation must finish without attempting login.
# shellcheck disable=SC2329  # called by the sourced install/update flows
select_version() { :; }
# shellcheck disable=SC2329
do_download() { STAGED_BIN="$NB_TEST_REAL_BIN"; }
NB_AUTH=key
NB_SETUP_KEY=''; NB_SETUP_KEY_FILE=''
do_install
[ ! -e "$NB_UP_ARGS_FILE" ]
_nb status
[ -S "$T/first.sock" ]
printf 'PASS: install completes without login and the real daemon answers on the configured socket\n'

# Update must preserve saved connection options without attempting login.
printf '%s\n' --interface-name nb-ci > "$NB_UP_ARGS_FILE"
cp "$NB_UP_ARGS_FILE" "$T/up-before"
NB_DAEMON_ADDR="unix://$T/second.sock"
do_update
cmp "$T/up-before" "$NB_UP_ARGS_FILE"
_nb status
[ -S "$T/second.sock" ]
printf 'PASS: running binary replacement and socket change take effect\n'

svc_stop
if _daemon_running; then
    printf 'FAIL: daemon still running after stop\n' >&2
    exit 1
fi
printf 'PASS: real systemd daemon stops\n'

# A unit whose executable immediately exits must not be reported ready.
printf '[Service]\nExecStart=/bin/false\n' > "$unit"
if svc_restart; then
    printf 'FAIL: broken service reported ready\n' >&2
    exit 1
fi
printf 'PASS: broken systemd service propagates failure\n'
