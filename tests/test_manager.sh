#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043  # `local` — supported by every shell this project targets
# shellcheck disable=SC1091  # the script under test is sourced by path
# shellcheck disable=SC2034  # NB_* variables are consumed by the sourced script, not by this file
# Unit tests for the pure helpers in netbird.sh. No network, no root, no side effects:
# the script is sourced with NB_SOURCE_ONLY=1 so main() never runs.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)

FAIL=0
PASS=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# assert_eq <label> <expected> <actual>
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"
    else bad "$1"; printf '       expected: %s\n       actual:   %s\n' "$2" "$3"; fi
}
# assert_true <label> <command…>
assert_true()  { local l="$1"; shift; if "$@"; then ok "$l";  else bad "$l"; fi; }
assert_false() { local l="$1"; shift; if "$@"; then bad "$l"; else ok "$l"; fi; }

NB_SOURCE_ONLY=1
export NB_SOURCE_ONLY
# shellcheck source=../netbird.sh
. "${SCRIPT_DIR}/netbird.sh"

printf '\n== asset names ==\n'
assert_eq "asset arm64"  "netbird_0.78.1_linux_arm64.tar.gz"  "$(asset_name v0.78.1 arm64)"
assert_eq "asset amd64"  "netbird_0.78.1_linux_amd64.tar.gz"  "$(asset_name 0.78.1 amd64)"
assert_eq "asset mipsle" "netbird_0.59.0_linux_mipsle_softfloat.tar.gz" \
                         "$(asset_name v0.59.0 mipsle_softfloat)"

printf '\n== arch override ==\n'
for a in amd64 arm64 armv6 386 mips_softfloat mipsle_hardfloat mips64le_softfloat; do
    NB_ARCH="$a"; ARCH_NAME=""
    _detect_arch >/dev/null 2>&1
    assert_eq "NB_ARCH=$a" "$a" "$ARCH_NAME"
done
NB_ARCH="riscv64"; ARCH_NAME=""
assert_false "NB_ARCH=riscv64 rejected (no upstream build)" _detect_arch
NB_ARCH=""

printf '\n== validators ==\n'
assert_true  "port 51820"        is_valid_port 51820
assert_false "port 0"            is_valid_port 0
assert_false "port 70000"        is_valid_port 70000
assert_false "port abc"          is_valid_port abc
assert_true  "mtu 1280"          is_valid_mtu 1280
assert_false "mtu 1200"          is_valid_mtu 1200
assert_true  "url https"         is_valid_http_url "https://netbird.example.com:443"
assert_false "url ssh"           is_valid_http_url "ssh://netbird.example.com"
assert_false "url injection"     is_valid_http_url "https://a.com;rm -rf /"
assert_true  "ipv4"              is_valid_ipv4 "127.0.0.1"
assert_false "ipv4 out of range" is_valid_ipv4 "300.1.1.1"
assert_true  "hostport"          is_valid_hostport "127.0.0.1:5053"
assert_false "hostport no port"  is_valid_hostport "127.0.0.1"
assert_true  "iface wt0"         is_valid_iface_name "wt0"
assert_false "iface with slash"  is_valid_iface_name "wt0/x"
assert_true  "hostname"          is_valid_hostname "router-a"
assert_false "hostname space"    is_valid_hostname "router a"
assert_true  "tag v0.78.1"       is_valid_version_tag "v0.78.1"
assert_true  "tag pre"           is_valid_version_tag "v0.79.0-rc.1"
assert_false "tag no v"          is_valid_version_tag "0.78.1"
assert_true  "bool 1"            _bool_value 1
assert_true  "bool yes"          _bool_value yes
assert_false "bool 0"            _bool_value 0
assert_false "arg with newline"  is_safe_arg_value "$(printf 'a\nb')"

printf '\n== systemd escaping ==\n'
assert_eq "percent doubled" "--x 100%%" "$(_systemd_escape_args '--x 100%')"

printf '\n== download URL order ==\n'
BASE="https://github.com/netbirdio/netbird/releases/download/v0.78.1/x.tar.gz"
NB_GITHUB_MIRROR=""
NB_GITHUB_MIRRORS="https://m1 https://m2"
assert_eq "direct first, mirrors after" \
    "$(printf '%s\nhttps://m1/%s\nhttps://m2/%s' "$BASE" "$BASE" "$BASE")" \
    "$(_download_urls "$BASE")"
NB_GITHUB_MIRROR="https://ghfast.top/"
assert_eq "explicit mirror first, direct as fallback" \
    "$(printf 'https://ghfast.top/%s\n%s' "$BASE" "$BASE")" \
    "$(_download_urls "$BASE")"
NB_GITHUB_MIRROR=""; NB_GITHUB_MIRRORS=""

printf '\n== release list parsing ==\n'
RELEASES='[{"url":"https://api.github.com/x/1","id":1,"author":{"login":"bot","id":9},
"node_id":"RE_1","tag_name":"v0.79.0-rc.1","target_commitish":"main","name":"v0.79.0-rc.1",
"draft":false,"prerelease":true,"created_at":"2026-08-01T00:00:00Z","assets":[]},
{"url":"https://api.github.com/x/2","id":2,"author":{"login":"bot","id":9},
"node_id":"RE_2","tag_name":"v0.78.1","target_commitish":"main","name":"v0.78.1",
"draft":false,"prerelease":false,"created_at":"2026-07-01T00:00:00Z","assets":[]},
{"url":"https://api.github.com/x/3","id":3,"author":{"login":"bot","id":9},
"node_id":"RE_3","tag_name":"v0.78.0","target_commitish":"main","name":"v0.78.0",
"draft":true,"prerelease":false,"created_at":"2026-06-01T00:00:00Z","assets":[]}]'

PARSED=$(printf '%s' "$RELEASES" | _parse_releases)
assert_eq "three releases parsed" \
    "$(printf 'v0.79.0-rc.1 true false\nv0.78.1 false false\nv0.78.0 false true')" "$PARSED"
assert_eq "latest stable, drafts excluded" "v0.78.1" \
    "$(printf '%s\n' "$PARSED" | awk '$3 == "false" && $2 == "false" {print $1; exit}')"
assert_eq "latest incl. pre-release" "v0.79.0-rc.1" \
    "$(printf '%s\n' "$PARSED" | awk '$3 == "false" {print $1; exit}')"

printf '\n== asset digest parsing ==\n'
# Field order mirrors the real API: name … uploader{} … digest … browser_download_url.
# The decoy asset name contains the wanted one as a substring and must not match.
ASSETS='{"tag_name":"v0.78.1","assets":[
{"url":"https://api.github.com/a/1","id":1,"node_id":"A1",
"name":"netbird-idp-migrate_0.78.1_linux_arm64.tar.gz","label":null,
"uploader":{"login":"bot","id":9,"url":"https://api.github.com/u/9"},
"content_type":"application/gzip","state":"uploaded","size":100,
"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111",
"download_count":1,"browser_download_url":"https://example/1"},
{"url":"https://api.github.com/a/2","id":2,"node_id":"A2",
"name":"netbird_0.78.1_linux_arm64.tar.gz","label":null,
"uploader":{"login":"bot","id":9,"url":"https://api.github.com/u/9"},
"content_type":"application/gzip","state":"uploaded","size":200,
"digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222",
"download_count":2,"browser_download_url":"https://example/2"}]}'

_digest_of() {
    printf '%s' "$ASSETS" | _json_lines | awk -v want="$1" '
        index($0, "\"name\":\"" want "\"") { f = 1; next }
        f && /^"digest":"sha256:/ {
            d = $0; sub(/^"digest":"sha256:/, "", d); sub(/[^0-9a-f].*$/, "", d)
            if (length(d) == 64) { print d; exit }
        }
        f && /^"browser_download_url":/ { f = 0 }
    '
}
assert_eq "digest of the exact asset" \
    "2222222222222222222222222222222222222222222222222222222222222222" \
    "$(_digest_of netbird_0.78.1_linux_arm64.tar.gz)"
assert_eq "digest of the decoy asset" \
    "1111111111111111111111111111111111111111111111111111111111111111" \
    "$(_digest_of netbird-idp-migrate_0.78.1_linux_arm64.tar.gz)"
assert_eq "unknown asset yields nothing" "" "$(_digest_of netbird_9.9.9_linux_arm64.tar.gz)"

printf '\n== prompts ==\n'
# Regression: _read_text is always called as ans=$(_read_text …), so a prompt written to stdout
# is both invisible to the user and glued onto the answer — every menu choice then falls through
# to "Unknown choice". Only the answer may reach stdout; the prompt belongs on stderr.
assert_eq "answer only, prompt not captured"  "3" "$(printf '3\n'  | _read_text "Choice" "" 2>/dev/null)"
assert_eq "empty input falls back to default" "7" "$(printf '\n'   | _read_text "Choice" "7" 2>/dev/null)"
assert_eq "answer wins over the default"      "2" "$(printf '2\n'  | _read_text "Choice" "7" 2>/dev/null)"
assert_eq "answer keeps inner spaces"    "a b c" "$(printf 'a b c\n' | _read_text "Name" "" 2>/dev/null)"
if [ -n "$(printf '3\n' | _read_text "Choice" "" 2>&1 >/dev/null)" ]; then
    ok "the prompt is still shown, on stderr"
else
    bad "the prompt is still shown, on stderr"
fi
assert_eq "secret answer is returned" "k3y" "$(printf 'k3y\n' | _read_secret "Setup key" 2>/dev/null)"

# _ask_flag answers through its exit status, so its prompt must not pollute stdout either
assert_true  "yes is accepted"     sh -c "printf 'y\n' | { . '${SCRIPT_DIR}/netbird.sh'; _ask_flag Q n; }" 2>/dev/null
assert_false "no is accepted"      sh -c "printf 'n\n' | { . '${SCRIPT_DIR}/netbird.sh'; _ask_flag Q y; }" 2>/dev/null
assert_true  "empty takes default" sh -c "printf '\n'  | { . '${SCRIPT_DIR}/netbird.sh'; _ask_flag Q y; }" 2>/dev/null

printf '\n== generated files ==\n'
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
NB_ETC_DIR="$T/etc/netbird"
NB_CONFIG_FILE=""            # default: let the client pick its own profile path
NB_DAEMON_ARGS_FILE="$NB_ETC_DIR/daemon.args"
NB_UP_ARGS_FILE="$NB_ETC_DIR/up.args"
NB_BIN_DIR="$T/usr/bin"; NB_BIN="$NB_BIN_DIR/netbird"
NB_INITD_DIR="$T/etc/init.d"; NB_SYSTEMD_DIR="$T/etc/systemd/system"
NB_LOG_FILE="console"; NB_LOG_LEVEL="info"; NB_DAEMON_ADDR=""

write_daemon_args >/dev/null 2>&1
assert_eq "daemon.args is one argument per line" \
    "$(printf 'service\nrun\n--log-level\ninfo\n--log-file\nconsole')" \
    "$(cat "$NB_DAEMON_ARGS_FILE")"

# --config is deprecated upstream and its default path moved between releases: emit it only
# when the operator asks for it.
NB_CONFIG_FILE="$T/etc/netbird/profile.json"
write_daemon_args >/dev/null 2>&1
if grep -qxF -- '--config' "$NB_DAEMON_ARGS_FILE"; then ok "explicit NB_CONFIG_FILE is passed through"
else bad "explicit NB_CONFIG_FILE is passed through"; fi
NB_CONFIG_FILE=""
write_daemon_args >/dev/null 2>&1
if grep -qxF -- '--config' "$NB_DAEMON_ARGS_FILE"; then bad "no --config by default"
else ok "no --config by default"; fi

for init in procd systemd openrc; do
    INIT_SYS="$init"
    svc_write >/dev/null 2>&1
    f=$(svc_file_path)
    if [ -f "$f" ]; then ok "$init service file written"; else bad "$init service file written"; continue; fi
    if grep -q "$NB_MANAGED_MARK" "$f"; then ok "$init file carries the managed-by marker"
    else bad "$init file carries the managed-by marker"; fi
    if grep -q -- "$NB_BIN" "$f"; then ok "$init file references the installed binary"
    else bad "$init file references the installed binary"; fi
    INIT_SYS="$init"
    assert_false "$init file is not treated as foreign" svc_foreign
done

INIT_SYS="systemd"
if grep -q -- '--log-file console' "$(svc_file_path)"; then ok "systemd ExecStart carries the daemon args"
else bad "systemd ExecStart carries the daemon args"; fi
# procd and openrc share /etc/init.d/netbird, so re-write the procd flavour before inspecting it
INIT_SYS="procd"
svc_write >/dev/null 2>&1
if grep -q 'procd_append_param command' "$(svc_file_path)"; then ok "procd reads daemon.args line by line"
else bad "procd reads daemon.args line by line"; fi

# a hand-written / package-installed unit must be detected rather than silently replaced
printf '#!/bin/sh\n# someone else\n' > "$(svc_file_path)"
assert_true "a foreign service file is detected" svc_foreign

printf '\n== up.args ==\n'
NB_MANAGEMENT_URL="https://nb.example.com:443"
NB_HOSTNAME="router-a"
NB_INTERFACE_NAME="wt0"
NB_DNS_RESOLVER_ADDRESS="127.0.0.1:5053"
NB_DISABLE_SERVER_ROUTES=1
NB_NETWORK_MONITOR=1
NB_SETUP_KEY="SUPER-SECRET-KEY"
write_up_args >/dev/null 2>&1
UP=$(cat "$NB_UP_ARGS_FILE")
for want in "--management-url" "https://nb.example.com:443" "--hostname" "router-a" \
            "--dns-resolver-address" "127.0.0.1:5053" "--disable-server-routes" \
            "--network-monitor=true"; do
    if printf '%s\n' "$UP" | grep -qxF -- "$want"; then ok "up.args contains $want"
    else bad "up.args contains $want"; fi
done
if printf '%s\n' "$UP" | grep -q 'SUPER-SECRET-KEY'; then bad "setup key must never be written to disk"
else ok "setup key is never written to disk"; fi
assert_eq "up.args is owner-readable only" "600" "$(stat -c '%a' "$NB_UP_ARGS_FILE" 2>/dev/null)"

# a bad value must be rejected before anything is written
NB_MTU="42"
assert_false "an out-of-range MTU is rejected" write_up_args
NB_MTU=""

printf '\n== saved settings are reloaded on a later run ==\n'
# A second run of the script must act on what is deployed, not on this run's defaults: otherwise
# the firewall zone binds wt0 while the client uses nb0, and the DNS entry forwards the wrong
# domain. Bool flags in up.args have no value line, so the parser must not mistake the following
# flag for one.
cat > "$NB_UP_ARGS_FILE" <<'ARGS'
--management-url
https://nb.example.com:443
--disable-server-routes
--interface-name
nb0
--block-inbound
--dns-resolver-address
127.0.0.1:5353
ARGS
NB_MANAGEMENT_URL=""; NB_INTERFACE_NAME="wt0"; NB_DNS_RESOLVER_ADDRESS=""
_u_mgmt=""; _u_iface=""; _u_resolver=""
load_saved_args
assert_eq "management URL restored"  "https://nb.example.com:443" "$NB_MANAGEMENT_URL"
assert_eq "interface name restored"  "nb0"                        "$NB_INTERFACE_NAME"
assert_eq "resolver address restored" "127.0.0.1:5353"            "$NB_DNS_RESOLVER_ADDRESS"
assert_eq "self-hosted DNS domain derived" "netbird.selfhosted"   "$(_derive_dns_domain)"

# an explicit environment value must survive the reload
NB_INTERFACE_NAME="from-env"; _u_iface=1
load_saved_args
assert_eq "explicit env value wins over the saved one" "from-env" "$NB_INTERFACE_NAME"
_u_iface=""

# cloud default when nothing is self-hosted
NB_MANAGEMENT_URL=""; NB_DNS_DOMAIN=""
assert_eq "cloud DNS domain derived" "netbird.cloud" "$(_derive_dns_domain)"

printf '\n== uci section lookup ==\n'
# The helpers must scan `uci show`, not walk indices with `uci get`: a section missing the probed
# option would end the walk early and hide every section after it.
# shellcheck disable=SC2329,SC2317  # invoked indirectly, from the sourced script's helpers
uci() {
    [ "$1" = "-q" ] && shift
    [ "$1" = "show" ] || return 1
    cat <<'UCI'
firewall.@zone[0]=zone
firewall.@zone[0].name='lan'
firewall.@zone[1]=zone
firewall.@zone[2]=zone
firewall.@zone[2].name='netbird'
firewall.@forwarding[0]=forwarding
firewall.@forwarding[0].src='lan'
firewall.@forwarding[0].dest='wan'
firewall.@forwarding[1]=forwarding
firewall.@forwarding[1].src='lan'
firewall.@forwarding[1].dest='netbird'
UCI
}
assert_eq "zone found past an unnamed section" "2" "$(_uci_zone_index)"
assert_eq "first netbird forwarding found"     "1" "$(_uci_forwarding_netbird_index)"
unset -f uci 2>/dev/null || uci() { return 1; }

printf '\n== summary ==\n'
printf '  %s passed, %s failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
