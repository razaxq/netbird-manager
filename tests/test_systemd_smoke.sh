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
mkdir -p "$NB_BIN_DIR"
cp "$NB_TEST_REAL_BIN" "$NB_BIN"
chmod 755 "$NB_BIN"

write_daemon_args
svc_write
svc_start
_nb status
[ -S "$T/first.sock" ]
printf 'PASS: real systemd daemon starts and answers on the configured socket\n'

# Exercise the actual replacement and service-file path with the already-verified
# release, avoiding a redundant download. Authentication is deliberately omitted.
STAGED_BIN="$NB_TEST_REAL_BIN"
NB_DAEMON_ADDR="unix://$T/second.sock"
do_install_bin
write_daemon_args
svc_write
svc_restart
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
