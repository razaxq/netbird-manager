#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC1091,SC2034  # source-under-test and its configuration variables
# shellcheck disable=SC2317,SC2329  # test doubles called by sourced functions
# shellcheck disable=SC2030,SC2031  # each scenario deliberately isolates its variables in a subshell
# Offline flow regressions. Every file and service double lives in a throwaway prefix.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1
NB_SOURCE_ONLY=1
NB_NONINTERACTIVE=1
NB_BIN_DIR="$T/bin"
NB_ETC_DIR="$T/etc"
NB_INITD_DIR="$T/init.d"
NB_SYSTEMD_DIR="$T/systemd"
NB_LOG_FILE=console
LOG_FILE="$T/manager.log"
# shellcheck source=../netbird.sh
. "${NB_TEST_SCRIPT:-${SCRIPT_DIR}/netbird.sh}"
trap '_cleanup; rm -rf "$T"' EXIT
mkdir -p "$NB_BIN_DIR" "$NB_ETC_DIR" "$NB_INITD_DIR" "$NB_SYSTEMD_DIR"
cat > "$NB_BIN" <<'CLIENT'
#!/bin/sh
printf '0.78.1\n'
CLIENT
chmod +x "$NB_BIN"

PASS=0; FAIL=0; SKIP=0
check() {
    label=$1; shift
    if "$@"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$label"
    else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$label"; fi
}

private_tmp() (
    TMPDIR="$T/staging"; mkdir -p "$TMPDIR/nb_mgr_$$"
    printf keep > "$TMPDIR/nb_mgr_$$/marker"
    TMP_DIR=''
    _ensure_tmp_dir || exit 1
    first=$TMP_DIR
    [ "$first" != "$TMPDIR/nb_mgr_$$" ] || exit 1
    _ensure_tmp_dir || exit 1
    [ "$TMP_DIR" = "$first" ] || exit 1
    _cleanup
    [ ! -d "$first" ] && [ "$(cat "$TMPDIR/nb_mgr_$$/marker")" = keep ]
)
check 'private staging ignores and does not clean attacker-precreated paths' private_tmp

private_mode() (
    TMP_DIR=''
    _ensure_tmp_dir || exit 1
    mode=$(stat -c %a "$TMP_DIR")
    _cleanup
    [ "$mode" = 700 ]
)
case "$(uname -s)" in
    MINGW*|MSYS*) SKIP=$((SKIP + 1)); printf '  SKIP Unix mode 0700 requires a Unix filesystem\n' ;;
    *) check 'private staging is mode 0700' private_mode ;;
esac

tmp_failure() (
    TMP_DIR=''
    mktemp() { return 1; }
    ! _ensure_tmp_dir && [ -z "$TMP_DIR" ]
)
check 'temp allocation failure does not fall back to a predictable directory' tmp_failure

key_environment() (
    NB_BIN="$T/key-client"
    cat > "$NB_BIN" <<'CLIENT'
#!/bin/sh
[ "${NB_SETUP_KEY+x}${WT_SETUP_KEY+x}${NB_SETUP_KEY_FILE+x}${WT_SETUP_KEY_FILE+x}" = '' ] || exit 21
printf '%s\n' "$@" > "$TEST_ARGS"
while [ "$#" -gt 0 ]; do
    if [ "$1" = --setup-key-file ]; then
        shift
        [ "$(cat "$1")" = review-dummy-key ] || exit 22
        printf '%s' "$1" > "$TEST_KEY_PATH"
        exit "${TEST_CLIENT_RC:-0}"
    fi
    shift
done
exit 23
CLIENT
    chmod +x "$NB_BIN"
    TEST_ARGS="$T/key-args"; TEST_KEY_PATH="$T/key-path"
    export TEST_ARGS TEST_KEY_PATH
    NB_AUTH=key; NB_SETUP_KEY=review-dummy-key; NB_SETUP_KEY_FILE=''
    WT_SETUP_KEY=legacy-dummy-key; WT_SETUP_KEY_FILE=/unused/legacy.key
    export NB_SETUP_KEY NB_SETUP_KEY_FILE WT_SETUP_KEY WT_SETUP_KEY_FILE
    NB_UP_ARGS_FILE="$T/no-up-args"; TMP_DIR=''
    _daemon_running() { return 0; }; wait_daemon() { return 0; }
    do_connect >/dev/null || exit 1
    [ "$NB_SETUP_KEY" = review-dummy-key ] || exit 1
    [ ! -e "$(cat "$TEST_KEY_PATH")" ] || exit 1
    ! grep -q review-dummy-key "$TEST_ARGS" || exit 1
    # A failed client must also propagate failure and remove the transient key.
    TEST_CLIENT_RC=42; export TEST_CLIENT_RC
    if do_connect >/dev/null 2>&1; then exit 1; fi
    [ ! -e "$(cat "$TEST_KEY_PATH")" ] || exit 1
    # An operator-supplied file belongs to the operator and must survive.
    TEST_CLIENT_RC=0; NB_SETUP_KEY_FILE="$T/operator.key"
    printf 'review-dummy-key\n' > "$NB_SETUP_KEY_FILE"
    do_connect >/dev/null || exit 1
    [ "$(cat "$NB_SETUP_KEY_FILE")" = review-dummy-key ] || exit 1
    _cleanup
)
check 'key auth scrubs inherited credentials and cleans only its own key file' key_environment

if [ -n "${NB_TEST_REAL_BIN:-}" ]; then
    real_key_environment() (
        NB_BIN="$NB_TEST_REAL_BIN"
        NB_SETUP_KEY=review-dummy-key; WT_SETUP_KEY=legacy-dummy-key
        NB_SETUP_KEY_FILE=/unused/dummy.key; WT_SETUP_KEY_FILE=/unused/legacy.key
        export NB_SETUP_KEY WT_SETUP_KEY NB_SETUP_KEY_FILE WT_SETUP_KEY_FILE
        # version exercises Cobra's real mutually-exclusive flag validation without
        # connecting, installing a service or reading a peer's configuration.
        _nb version --setup-key-file /unused/dummy.key >/dev/null
    )
    check 'official NetBird accepts the sanitized key-file invocation' real_key_environment
fi

bool_roundtrip() (
    NB_ALLOW_SERVER_SSH=1; NB_DISABLE_DNS=1
    write_up_args >/dev/null || exit 1
    grep -qxF -- '--allow-server-ssh=true' "$NB_UP_ARGS_FILE" || exit 1
    NB_ALLOW_SERVER_SSH=0; NB_DISABLE_DNS=0
    write_up_args >/dev/null || exit 1
    grep -qxF -- '--allow-server-ssh=false' "$NB_UP_ARGS_FILE" || exit 1
    grep -qxF -- '--disable-dns=false' "$NB_UP_ARGS_FILE" || exit 1
    NB_ALLOW_SERVER_SSH=1; NB_DISABLE_DNS=1
    _u_allow_server_ssh=''; _u_disable_dns=''
    load_saved_args
    ! _bool_value "$NB_ALLOW_SERVER_SSH" && ! _bool_value "$NB_DISABLE_DNS" || exit 1
    printf '%s\n' --allow-server-ssh --block-inbound > "$NB_UP_ARGS_FILE"
    _u_block_inbound=''; load_saved_args
    _bool_value "$NB_ALLOW_SERVER_SSH" && _bool_value "$NB_BLOCK_INBOUND" || exit 1
    NB_ALLOW_SERVER_SSH=0; _u_allow_server_ssh=x; load_saved_args
    ! _bool_value "$NB_ALLOW_SERVER_SSH"
)
check 'boolean settings round-trip false, migrate bare flags and respect explicit overrides' bool_roundtrip

wizard_disable() (
    NB_NONINTERACTIVE=0; NB_AUTH=none
    NB_ALLOW_SERVER_SSH=1; NB_ENABLE_ROSENPASS=1; NB_DISABLE_DNS=1
    NB_DISABLE_CLIENT_ROUTES=1; NB_DISABLE_SERVER_ROUTES=1
    printf '1\n3\n\ny\n\n\n\ny\ny\ny\nn\nn\n' > "$T/answers"
    _up_wizard < "$T/answers" >/dev/null 2>&1 || exit 1
    [ "$NB_ALLOW_SERVER_SSH:$NB_ENABLE_ROSENPASS:$NB_DISABLE_DNS:$NB_DISABLE_CLIENT_ROUTES:$NB_DISABLE_SERVER_ROUTES" = 0:0:0:0:0 ]
)
check 'wizard can reverse previously selected SSH, DNS, routes and Rosenpass choices' wizard_disable

daemon_roundtrip() (
    NB_CONFIG_FILE=/custom/identity.json; NB_DAEMON_ADDR=unix:///custom/netbird.sock
    NB_LOG_LEVEL=debug; NB_LOG_FILE=/custom/client.log
    write_daemon_args || exit 1
    cp "$NB_DAEMON_ARGS_FILE" "$T/original-daemon.args"
    rm -f "$NB_UP_ARGS_FILE"
    _u_config=''; _u_addr=''; _u_level=''; _u_logfile=''
    NB_CONFIG_FILE=''; NB_DAEMON_ADDR=''; NB_LOG_LEVEL=info; NB_LOG_FILE=console
    load_saved_args
    write_daemon_args || exit 1
    cmp "$T/original-daemon.args" "$NB_DAEMON_ARGS_FILE" || exit 1
    NB_CONFIG_FILE=''; NB_DAEMON_ADDR=unix:///new.sock; _u_config=x; _u_addr=x
    load_saved_args
    [ -z "$NB_CONFIG_FILE" ] && [ "$NB_DAEMON_ADDR" = unix:///new.sock ]
)
check 'daemon identity, socket and logs survive later runs; explicit overrides still win' daemon_roundtrip

router_log_roundtrip() (
    printf '%s\n' service run --log-file /custom/router.log > "$NB_DAEMON_ARGS_FILE"
    _u_logfile=''
    detect_system() { INIT_SYS=procd; }
    show_version() { [ "$NB_LOG_FILE" = /custom/router.log ] || exit 1; }
    main version
)
check 'router defaults do not overwrite a saved daemon log target' router_log_roundtrip

systemd_order() (
    INIT_SYS=systemd
    systemctl() { printf '%s\n' "$*" >> "$T/events"; }
    wait_daemon() { printf 'ready\n' >> "$T/events"; }
    : > "$T/events"
    svc_restart || exit 1
    [ "$(cat "$T/events")" = "$(printf 'daemon-reload\nrestart netbird\nready')" ]
)
check 'systemd reloads the unit before restarting and checking readiness' systemd_order

service_failure() (
    INIT_SYS=systemd
    systemctl() { return 42; }
    wait_daemon() { return 0; }
    ! svc_stop && ! svc_start && ! svc_restart
)
check 'systemd stop/start/restart propagate service-manager failure' service_failure

readiness_failure() (
    INIT_SYS=systemd
    systemctl() { return 0; }
    wait_daemon() { return 1; }
    ! svc_start && ! svc_restart
)
check 'successful service commands are not success until the daemon answers' readiness_failure

flow_failure() (
    INIT_SYS=systemd
    check_deps() { :; }; select_version() { :; }; do_download() { :; }
    do_install_bin() { :; }; svc_foreign() { return 1; }
    _up_wizard() { NB_AUTH=none; }
    write_up_args() { :; }; write_daemon_args() { :; }; svc_write() { :; }
    svc_start() { return 42; }; svc_restart() { return 42; }
    do_connect() { printf 'connect\n' >> "$T/events"; }
    : > "$T/events"
    ! do_install > "$T/flow-output" 2>&1 || exit 1
    ! do_update >> "$T/flow-output" 2>&1 || exit 1
    ! do_reconfigure >> "$T/flow-output" 2>&1 || exit 1
    [ ! -s "$T/events" ] && ! grep -qi finished "$T/flow-output"
)
check 'install/update/reconfigure abort without a success message when the service fails' flow_failure

stop_before_replace() (
    STAGED_BIN="$T/replacement"; printf replacement > "$STAGED_BIN"
    before=$(cat "$NB_BIN")
    _check_space() { return 0; }; _daemon_running() { return 0; }; svc_stop() { return 42; }
    ! do_install_bin >/dev/null 2>&1 && [ "$(cat "$NB_BIN")" = "$before" ]
)
check 'failed stop prevents replacing the live binary' stop_before_replace

update_preserves_args() (
    INIT_SYS=systemd
    NB_CONFIG_FILE=/custom/identity.json; NB_DAEMON_ADDR=unix:///custom/netbird.sock
    write_daemon_args || exit 1
    cp "$NB_DAEMON_ARGS_FILE" "$T/update-before"
    _u_config=''; _u_addr=''; NB_CONFIG_FILE=''; NB_DAEMON_ADDR=''
    load_saved_args
    check_deps() { :; }; select_version() { :; }; do_download() { :; }; do_install_bin() { :; }
    svc_restart() { :; }
    do_update >/dev/null || exit 1
    cmp "$T/update-before" "$NB_DAEMON_ARGS_FILE"
)
check 'update preserves the deployed daemon configuration' update_preserves_args

update_socket_order() (
    INIT_SYS=systemd; NB_MIN_BIN_MB=0; NB_BACKUP_KEEP=0
    NB_DAEMON_ADDR=unix:///old.sock
    write_daemon_args || exit 1
    NB_DAEMON_ADDR=unix:///new.sock
    check_deps() { :; }; select_version() { :; }; sleep() { :; }
    do_download() { STAGED_BIN="$T/new-client"; cp "$NB_BIN" "$STAGED_BIN"; }
    _daemon_running() { return 0; }
    svc_stop() { printf 'stop\n' >> "$T/events"; }
    svc_start() { printf 'premature start\n' >> "$T/events"; return 1; }
    svc_restart() {
        grep -qxF unix:///new.sock "$NB_DAEMON_ARGS_FILE" || return 1
        grep -qF unix:///new.sock "$(svc_file_path)" || return 1
        printf 'restart\n' >> "$T/events"
    }
    : > "$T/events"
    do_update >/dev/null || exit 1
    [ "$(cat "$T/events")" = "$(printf 'stop\nrestart')" ]
)
check 'updating a running client applies the new socket before restarting' update_socket_order

# Catch router configuration/service access, including legacy opt-in variables.
for service in network firewall dnsmasq; do
    cat > "$NB_INITD_DIR/$service" <<'SERVICE'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$TEST_EVENTS"
exit 42
SERVICE
    chmod +x "$NB_INITD_DIR/$service"
done
TEST_EVENTS="$T/router-events"; export TEST_EVENTS

program_only() (
    INIT_SYS=procd; NB_OPENWRT_DNS=1; NB_OPENWRT_FIREWALL=1
    NB_STATE_DIR="$T/state"
    uci() { printf 'uci\n' >> "$TEST_EVENTS"; return 42; }
    ubus() { printf 'ubus\n' >> "$TEST_EVENTS"; return 42; }
    check_deps() { :; }; select_version() { :; }; do_download() { :; }
    do_install_bin() { :; }; svc_foreign() { return 1; }
    svc_start() { :; }; svc_restart() { :; }; svc_stop() { :; }; svc_remove() { :; }
    _daemon_running() { return 1; }
    _up_wizard() { printf 'wizard\n' >> "$TEST_EVENTS"; return 42; }
    do_connect() { printf 'connect\n' >> "$TEST_EVENTS"; return 42; }
    _ask_flag() {
        case "$1" in
            *dnsmasq*|*firewall*|*forwarding*|*OpenWrt*) printf 'router prompt\n' >> "$TEST_EVENTS" ;;
            'Remove the NetBird client'*) return 0 ;;
        esac
        return 1
    }
    NB_LANG=en
    : > "$TEST_EVENTS"
    # A fresh install must not create connection settings or require authentication.
    rm -f "$NB_UP_ARGS_FILE"
    NB_AUTH=key; NB_SETUP_KEY=''
    do_install >/dev/null || exit 1
    [ ! -e "$NB_UP_ARGS_FILE" ] || exit 1
    printf '%s\n' --interface-name nb-custom > "$NB_UP_ARGS_FILE"
    cp "$NB_UP_ARGS_FILE" "$T/up-before"
    for mode in 0 1; do
        NB_NONINTERACTIVE=$mode
        do_install >/dev/null || exit 1
        do_update >/dev/null || exit 1
        cmp "$T/up-before" "$NB_UP_ARGS_FILE" || exit 1
    done
    # Use a disposable copy so uninstall never removes the shared client double.
    NB_BIN="$T/uninstall-client"; cp "$NB_BIN_DIR/netbird" "$NB_BIN"
    do_uninstall >/dev/null || exit 1
    [ ! -e "$NB_BIN" ] || exit 1
    cmp "$T/up-before" "$NB_UP_ARGS_FILE" && [ ! -s "$TEST_EVENTS" ]
)
check 'install/update/uninstall leave router settings alone and never prompt for a connection' program_only

noninteractive_entry() (
    NB_NONINTERACTIVE=1
    detect_system() { INIT_SYS=procd; }
    id() { printf '0\n'; }
    do_install() { printf 'install\n' >> "$T/entry-events"; }
    do_update() { printf 'update\n' >> "$T/entry-events"; }
    do_reconfigure() { printf 'configure\n' >> "$T/entry-events"; }
    do_connect() { printf 'connect\n' >> "$T/entry-events"; }
    : > "$T/entry-events"
    main || exit 1
    NB_BIN="$T/not-installed"
    main || exit 1
    main configure || exit 1
    main up || exit 1
    [ "$(cat "$T/entry-events")" = "$(printf 'update\ninstall\nconfigure\nconnect')" ]
)
check 'noninteractive default only installs/updates; configure/up remain explicit actions' noninteractive_entry

manual_configuration() (
    INIT_SYS=procd; NB_NONINTERACTIVE=1; NB_AUTH=none
    NB_DNS_RESOLVER_ADDRESS=''; _u_resolver=''
    svc_restart() { :; }
    do_reconfigure >/dev/null || exit 1
    [ -f "$NB_UP_ARGS_FILE" ] || exit 1
    [ -z "$NB_DNS_RESOLVER_ADDRESS" ] || exit 1
    ! grep -qF -- --dns-resolver-address "$NB_UP_ARGS_FILE" || exit 1
    NB_DNS_RESOLVER_ADDRESS=127.0.0.1:5353
    do_reconfigure >/dev/null || exit 1
    grep -qxF 127.0.0.1:5353 "$NB_UP_ARGS_FILE"
)
check 'manual configure remains available and only pins DNS when explicitly requested' manual_configuration

manual_menu() (
    NB_AUTH=none; NB_NONINTERACTIVE=0
    _menu_header() { :; }; _menu_options() { :; }
    do_reconfigure() { printf 'configure\n' >> "$T/menu-events"; }
    do_connect() { [ "$NB_AUTH" != none ] && printf 'connect\n' >> "$T/menu-events"; }
    : > "$T/menu-events"
    printf '4\n\n5\n\n9\n' > "$T/menu-input"
    (menu < "$T/menu-input" >/dev/null 2>&1) || exit 1
    [ "$(cat "$T/menu-events")" = "$(printf 'configure\nconnect')" ]
)
check 'menu keeps explicit configure and saved-connection actions, including after configure-only' manual_menu

printf '\n  %s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
