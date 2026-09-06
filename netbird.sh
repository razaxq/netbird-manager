#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043  # `local` — not POSIX strict, but widely supported (dash/busybox)
# shellcheck disable=SC2059  # printf format with color vars / t() — intentional for ANSI codes & i18n
# shellcheck disable=SC2155  # declare-and-assign — readable for local scalar capture
# ==============================================================================
#  netbird-manager.sh — NetBird install & management script
#  Version: see SCRIPT_VERSION below (single source; menu title & logs both read it)
#  Repo: https://github.com/razaxq/netbird-manager
#  Upstream: https://github.com/netbirdio/netbird
#  License: MIT (c) 2026 razaxq
# ==============================================================================
#  Bilingual: one script, English + Chinese. Language pick order:
#    NB_LANG=en|zh   — explicit override
#    otherwise auto-detected from $LC_ALL / $LC_MESSAGES / $LANG (zh* → Chinese)
#    default: English
# ==============================================================================
#  Supported systems
#    OpenWrt / ImmortalWrt  (procd)          — including 21.02, where no netbird package exists
#    Debian / Ubuntu / Raspbian  (systemd)
#    RHEL / Fedora / Rocky / AlmaLinux  (systemd)
#    Arch Linux / Manjaro  (systemd)
#    Alpine Linux  (openrc)
#  Supported archs (upstream release matrix):
#    amd64 / arm64 / armv6 / 386 / mips / mipsle / mips64 / mips64le
#    (MIPS float ABI is auto-detected; soft-float is the safe default)
# ------------------------------------------------------------------------------
#  Non-interactive install (preset all params via env vars):
#    NB_NONINTERACTIVE=1         — skip all prompts, use defaults or the vars below
#    NB_LANG=en|zh               — force interface language
#    NB_VERSION=v0.78.1          — version to install
#    NB_AUTH=key|sso|none        — auth mode: setup key / interactive SSO / configure only
#    NB_SETUP_KEY=<key>          — setup key (never written to disk, never in argv)
#    NB_SETUP_KEY_FILE=<path>    — read the setup key from a file instead
#    NB_MANAGEMENT_URL=https://netbird.example.com:443  — self-hosted management server
#    NB_ADMIN_URL=https://...    — self-hosted dashboard URL (optional)
#    NB_PRESHARED_KEY=<key>      — self-hosted WireGuard pre-shared key (optional)
#    NB_HOSTNAME=router-a        — peer name shown in the dashboard
#    NB_INTERFACE_NAME=wt0       — WireGuard interface name
#    NB_WIREGUARD_PORT=51820     — WireGuard listen port
#    NB_MTU=1280                 — interface MTU
#    NB_DNS_RESOLVER_ADDRESS=127.0.0.1:5053  — NetBird resolver bind (procd default; 53 is dnsmasq's)
#    NB_DISABLE_DNS=1            — do not manage DNS at all
#    NB_DISABLE_CLIENT_ROUTES=1  — do not accept routes from other peers
#    NB_DISABLE_SERVER_ROUTES=1  — do not act as a routing peer
#    NB_DISABLE_FIREWALL=1       — do not manage firewall rules
#    NB_DISABLE_IPV6=1           — disable IPv6 inside the tunnel
#    NB_BLOCK_INBOUND=1          — drop all inbound peer traffic
#    NB_BLOCK_LAN_ACCESS=1       — block peers from reaching this host's LAN
#    NB_ALLOW_SERVER_SSH=1       — enable NetBird's built-in SSH server (off by default)
#    NB_ENABLE_ROSENPASS=1       — post-quantum key exchange (+ NB_ROSENPASS_PERMISSIVE=1)
#    NB_EXTRA_DNS_LABELS=a,b     — extra DNS labels for this peer
#    NB_EXTRA_IFACE_BLACKLIST=br-lan,docker0
#    NB_EXTERNAL_IP_MAP=1.2.3.4  — advertise a fixed external IP (NAT hairpin setups)
#    NB_NETWORK_MONITOR=1|0      — restart the connection on network changes
#    NB_LOG_LEVEL=info           — daemon log level (panic|fatal|error|warn|info|debug|trace)
#    NB_LOG_FILE=console         — daemon log file; "console" → procd/journald/OpenRC log
#    NB_CONFIG_FILE=<path>       — override the client profile/config path. Empty (the default)
#                                  means "let the client decide": 0.7x keeps it in
#                                  /var/lib/netbird/default.json, older builds in
#                                  /etc/netbird/config.json. Only set this if you must.
#    NB_DAEMON_ADDR=unix:///var/run/netbird.sock
#    NB_BIN_DIR=/usr/bin         — where the binary is installed
#    NB_OPENWRT_DNS=1            — OpenWrt: forward the NetBird DNS domain to it through dnsmasq
#    NB_OPENWRT_FIREWALL=1       — OpenWrt: create the netbird zone + lan<->netbird forwarding
#    NB_DNS_DOMAIN=netbird.cloud — the DNS domain to forward (netbird.selfhosted when self-hosting)
#    NB_ARCH=arm64               — override auto-detected release architecture
#    NB_ALLOW_PRERELEASE=1       — allow auto-selection of a pre-release
#    NB_ALLOW_VERSION_FALLBACK=1 — allow NB_DEFAULT_VERSION when the release API fails
#    NB_DEFAULT_VERSION=v0.78.1  — explicit fallback version (disabled by default)
#    NB_GITHUB_MIRROR=https://ghfast.top   — prefix mirror for github.com downloads (helps in CN)
#    NB_GITHUB_MIRRORS='<p1> <p2>'         — fallback prefixes tried after github.com (empty = off)
#    NB_GITHUB_API=https://api.github.com  — GitHub API base override (for an API mirror)
#    NB_GITHUB_TOKEN=<PAT>       — lift the 60/h anonymous API rate limit (or GITHUB_TOKEN)
#    NB_SHA256=<hex>             — expected sha256 of the release tarball (integrity check)
#    NB_ALLOW_UNVERIFIED=1       — explicitly allow an asset without a verified digest
#    NB_CACHE_TTL=600            — seconds to reuse the cached release list (0 disables)
#    NB_MIN_TMP_MB=110           — minimum free space in /tmp for download + extract
#    NB_MIN_BIN_MB=60            — minimum free space where the binary is installed
#    (curl also honors the standard https_proxy / http_proxy env vars)
#  Note: defaults live in the ── Tunables ── section below; on procd (OpenWrt) BACKUP_KEEP and the
#      log target are auto-tightened by main() (values you set explicitly still win)
# ==============================================================================

SCRIPT_VERSION="1.0.0"

# ── Tunables ──────────────────────────────────────────
# Sentinels record whether the user set the var explicitly; after detect_system, procd applies
# tighter defaults unless the value was set on purpose.
_u_backup=${NB_BACKUP_KEEP:+1}
_u_logfile=${NB_LOG_FILE:+1}
_u_resolver=${NB_DNS_RESOLVER_ADDRESS:+1}
_u_logpath=${LOG_FILE:+1}

NB_REPO="netbirdio/netbird"
NB_BACKUP_KEEP="${NB_BACKUP_KEEP:-3}"            # backups kept for the binary
NB_RELEASES_COUNT="${NB_RELEASES_COUNT:-20}"     # max releases to fetch in the list
NB_DEFAULT_VERSION="${NB_DEFAULT_VERSION:-v0.78.1}"  # opt-in fallback when the GitHub API fails
NB_ALLOW_VERSION_FALLBACK="${NB_ALLOW_VERSION_FALLBACK:-0}"
NB_ALLOW_PRERELEASE="${NB_ALLOW_PRERELEASE:-0}"
NB_ALLOW_UNVERIFIED="${NB_ALLOW_UNVERIFIED:-0}"
NB_ARCH="${NB_ARCH:-}"
LOG_FILE="${LOG_FILE:-/var/log/netbird-manager.log}"
TMP_DIR="/tmp/nb_mgr_$$"

# GitHub access — mirror/proxy/token/integrity/cache (all optional; empty = plain github.com)
NB_GITHUB_API="${NB_GITHUB_API:-https://api.github.com}"  # API base (override for a mirror)
NB_GITHUB_DIGEST_API="https://api.github.com"             # trusted digest source (never mirrored)
NB_GITHUB_MIRROR="${NB_GITHUB_MIRROR:-}"                  # ghproxy-style prefix for downloads
# Tried in order after github.com itself when NB_GITHUB_MIRROR is unset. Release assets cannot be
# served by jsDelivr (its /gh/ endpoint only exposes committed files, capped at 20MB), so these are
# ghproxy-style prefixes. Set to empty to disable the fallback entirely.
NB_GITHUB_MIRRORS="${NB_GITHUB_MIRRORS-https://ghfast.top https://gh-proxy.com}"
NB_GITHUB_TOKEN="${NB_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
NB_SHA256="${NB_SHA256:-}"
NB_CACHE_TTL="${NB_CACHE_TTL:-600}"
CACHE_DIR="${NB_CACHE_DIR:-${TMPDIR:-/tmp}/nb_mgr_cache}"  # persists across runs (not wiped)

# Install layout
NB_BIN_DIR="${NB_BIN_DIR:-/usr/bin}"
NB_BIN="${NB_BIN_DIR}/netbird"
NB_ETC_DIR="${NB_ETC_DIR:-/etc/netbird}"
# Empty on purpose: the client's own default profile path moved between releases
# (/etc/netbird/config.json → /var/lib/netbird/default.json), and pinning it with the now
# deprecated --config would fight the upstream default. Set it only to override deliberately.
NB_CONFIG_FILE="${NB_CONFIG_FILE:-}"
NB_DAEMON_ARGS_FILE="${NB_DAEMON_ARGS_FILE:-${NB_ETC_DIR}/daemon.args}"
NB_UP_ARGS_FILE="${NB_UP_ARGS_FILE:-${NB_ETC_DIR}/up.args}"
NB_STATE_DIR="${NB_STATE_DIR:-/var/lib/netbird}"
NB_SERVICE_NAME="netbird"
NB_MANAGED_MARK="# managed-by: netbird-manager"
# Service file locations. The overrides exist for distributors and for the test suite; a normal
# installation should leave them alone so the init system actually finds the unit.
NB_INITD_DIR="${NB_INITD_DIR:-/etc/init.d}"
NB_SYSTEMD_DIR="${NB_SYSTEMD_DIR:-/etc/systemd/system}"

# Daemon runtime
NB_LOG_LEVEL="${NB_LOG_LEVEL:-info}"
NB_LOG_FILE="${NB_LOG_FILE:-/var/log/netbird/client.log}"
NB_DAEMON_ADDR="${NB_DAEMON_ADDR:-}"     # empty = upstream default (unix:///var/run/netbird.sock)

# `netbird up` options. Security-sensitive capabilities are opt-in.
NB_AUTH="${NB_AUTH:-}"                   # key | sso | none
NB_SETUP_KEY="${NB_SETUP_KEY:-}"
NB_SETUP_KEY_FILE="${NB_SETUP_KEY_FILE:-}"
NB_MANAGEMENT_URL="${NB_MANAGEMENT_URL:-}"
NB_ADMIN_URL="${NB_ADMIN_URL:-}"
NB_PRESHARED_KEY="${NB_PRESHARED_KEY:-}"
NB_HOSTNAME="${NB_HOSTNAME:-}"
NB_INTERFACE_NAME="${NB_INTERFACE_NAME:-wt0}"
NB_WIREGUARD_PORT="${NB_WIREGUARD_PORT:-}"
NB_MTU="${NB_MTU:-}"
NB_DNS_RESOLVER_ADDRESS="${NB_DNS_RESOLVER_ADDRESS:-}"
NB_DISABLE_DNS="${NB_DISABLE_DNS:-0}"
NB_DISABLE_CLIENT_ROUTES="${NB_DISABLE_CLIENT_ROUTES:-0}"
NB_DISABLE_SERVER_ROUTES="${NB_DISABLE_SERVER_ROUTES:-0}"
NB_DISABLE_FIREWALL="${NB_DISABLE_FIREWALL:-0}"
NB_DISABLE_IPV6="${NB_DISABLE_IPV6:-0}"
NB_BLOCK_INBOUND="${NB_BLOCK_INBOUND:-0}"
NB_BLOCK_LAN_ACCESS="${NB_BLOCK_LAN_ACCESS:-0}"
NB_ALLOW_SERVER_SSH="${NB_ALLOW_SERVER_SSH:-0}"
NB_ENABLE_ROSENPASS="${NB_ENABLE_ROSENPASS:-0}"
NB_ROSENPASS_PERMISSIVE="${NB_ROSENPASS_PERMISSIVE:-0}"
NB_EXTRA_DNS_LABELS="${NB_EXTRA_DNS_LABELS:-}"
NB_EXTRA_IFACE_BLACKLIST="${NB_EXTRA_IFACE_BLACKLIST:-}"
NB_EXTERNAL_IP_MAP="${NB_EXTERNAL_IP_MAP:-}"
NB_NETWORK_MONITOR="${NB_NETWORK_MONITOR:-}"   # empty = client default

# OpenWrt integration (opt-in; the wizard offers them interactively)
NB_OPENWRT_DNS="${NB_OPENWRT_DNS:-0}"
NB_OPENWRT_FIREWALL="${NB_OPENWRT_FIREWALL:-0}"
NB_DNS_DOMAIN="${NB_DNS_DOMAIN:-}"       # empty → derived from NB_MANAGEMENT_URL

# Space requirements: tarball ~20MB, extracted binary ~50MB
NB_MIN_TMP_MB="${NB_MIN_TMP_MB:-110}"
NB_MIN_BIN_MB="${NB_MIN_BIN_MB:-60}"

# ── Runtime state (filled by detection, do not edit by hand) ──────────────
OS_TYPE=""      # openwrt | debian | rhel | arch | alpine | unknown
INIT_SYS=""     # procd | systemd | openrc | unknown
ARCH_NAME=""    # amd64 | arm64 | armv6 | 386 | mips… | unknown
VER=""          # selected version tag (set by select_version)
ASSET=""        # release asset filename for VER + ARCH_NAME
STAGED_BIN=""   # verified binary staged in TMP_DIR, ready to commit

# ==============================================================================
#  i18n — one script, two languages. t "<english>" "<chinese>" prints the right one.
#    · plain text line          → printf '%s\n' "$(t "EN" "ZH")"
#    · prompt (no newline)      → printf '%s'   "$(t "EN " "ZH ")"
#    · line with printf args    → printf "$(t "FMT_EN" "FMT_ZH")" args…
#  _log() diagnostic strings intentionally stay English for greppable logs.
# ==============================================================================
_LANG="en"
_detect_lang() {
    case "${NB_LANG:-}" in
        zh|zh[_-]*|ZH|Zh) _LANG="zh"; return ;;
        en|en[_-]*|EN|En) _LANG="en"; return ;;
        '') ;;
        *)  _LANG="en"; return ;;
    esac
    case "${LC_ALL:-}${LC_MESSAGES:-}${LANG:-}" in
        *zh*|*ZH*) _LANG="zh" ;;
        *)         _LANG="en" ;;
    esac
}
_detect_lang
t() { [ "$_LANG" = "zh" ] && printf '%s' "$2" || printf '%s' "$1"; }

# ==============================================================================
#  Colors & output (tty detection; falls back to no color when not a terminal)
# ==============================================================================
_init_colors() {
    if [ -t 1 ]; then
        C_RED=$(printf '\033[0;31m')
        C_GRN=$(printf '\033[0;32m')
        C_YLW=$(printf '\033[1;33m')
        C_CYN=$(printf '\033[0;36m')
        C_BLD=$(printf '\033[1m')
        C_DIM=$(printf '\033[2m')
        C_RST=$(printf '\033[0m')
    else
        C_RED=''; C_GRN=''; C_YLW=''; C_CYN=''; C_BLD=''; C_DIM=''; C_RST=''
    fi
}
_init_colors

msg_ok()   { printf "${C_GRN}  ✓${C_RST}  %s\n"  "$*"; _log "OK"   "$*"; }
msg_warn() { printf "${C_YLW}  ⚠${C_RST}  %s\n"  "$*"; _log "WARN" "$*"; }
msg_err()  { printf "${C_RED}  ✗${C_RST}  %s\n"  "$*" >&2; _log "ERR" "$*"; }
msg_info() { printf "${C_CYN}  ›${C_RST}  %s\n"  "$*"; }
die()      { msg_err "$*"; exit 1; }

# Print a runnable command with its label as a trailing shell comment, so selecting the whole
# line and pasting it still works. A "label : command" layout does not.  $1 command  $2 label
_cmd_hint() { printf "    %-42s ${C_DIM}# %s${C_RST}\n" "$1" "$2"; }

# The log command for the daemon, per init system.
#   $1 = "recent" (default, for diagnosing) | "follow" (for watching)
_svc_log_cmd() {
    local _mode="${1:-recent}"
    case "$INIT_SYS" in
        procd)
            if [ "$_mode" = follow ]; then printf 'logread -f -e netbird'
            else printf 'logread -e netbird'; fi ;;
        systemd)
            if [ "$_mode" = follow ]; then printf 'journalctl -u %s -f' "$NB_SERVICE_NAME"
            else printf 'journalctl -u %s -n 50 --no-pager' "$NB_SERVICE_NAME"; fi ;;
        *)
            if [ "$NB_LOG_FILE" = console ]; then
                if [ "$_mode" = follow ]; then printf 'tail -f /var/log/netbird.log'
                else printf 'tail -n 50 /var/log/netbird.log'; fi
            else
                if [ "$_mode" = follow ]; then printf 'tail -f %s' "$NB_LOG_FILE"
                else printf 'tail -n 50 %s' "$NB_LOG_FILE"; fi
            fi ;;
    esac
}

# Section heading
section() {
    local title="$1"
    local len="${#title}"
    printf "\n${C_BLD}  %s${C_RST}\n" "$title"
    printf "  "
    local i=0; while [ "$i" -lt $((len + 2)) ]; do printf "─"; i=$((i+1)); done
    printf "\n\n"
}

# ==============================================================================
#  Logging (append to file; failures silently ignored)
# ==============================================================================
_log() {
    local level="$1"; shift
    ( printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE" ) 2>/dev/null || true
}

# ==============================================================================
#  Cleanup & signal handling
#
#   - EXIT trap always wipes the temp dir (which may hold a setup key) and stray temp files.
#   - INT/TERM/HUP → _on_signal: notice, exit 130; the EXIT trap still cleans up.
#   - System-mutating operations are wrapped in crit_begin/crit_end: write to a temp file,
#     checkpoint with crit_ck, then commit with an atomic same-filesystem rename. At any instant
#     the target is either the complete old file or the complete new one — never truncated.
# ==============================================================================
_cleanup() {
    if [ -d "$TMP_DIR" ]; then
        # the staged setup key lives here; overwrite before unlinking where possible
        find "$TMP_DIR" -type f -name '*.key' -exec sh -c ': > "$1"' _ {} \; 2>/dev/null || true
        rm -rf "$TMP_DIR" 2>/dev/null || true
    fi
    rm -f "${NB_ETC_DIR}"/*.tmp.$$ "${NB_BIN_DIR}"/*.tmp.$$ \
          "${NB_INITD_DIR}"/*.tmp.$$ "${NB_SYSTEMD_DIR}"/*.tmp.$$ 2>/dev/null || true
}

_on_signal() {
    printf '\n'
    msg_warn "$(t "Interrupt received, exiting safely…" "收到中断信号，正在安全退出…")"
    exit 130
}

trap '_cleanup'   EXIT
trap '_on_signal' INT TERM HUP

_SIG_PENDING=0
crit_begin() { _SIG_PENDING=0; trap '_SIG_PENDING=1' INT TERM HUP; }
crit_ck() {
    [ "$_SIG_PENDING" = "1" ] || return 0
    [ "$#" -gt 0 ] && rm -f "$@" 2>/dev/null
    trap '_on_signal' INT TERM HUP
    printf '\n'
    msg_warn "$(t "Interrupted as requested; uncommitted changes discarded, exiting safely" \
                  "已按请求中断，未提交的改动已丢弃，安全退出")"
    exit 130
}
crit_end() {
    trap '_on_signal' INT TERM HUP
    if [ "$_SIG_PENDING" = "1" ]; then
        printf '\n'
        msg_warn "$(t "Current operation completed; exiting safely as requested" \
                      "当前操作已完成，按您的请求安全退出")"
        exit 130
    fi
    return 0
}

# Create the staging file with 0600 *before* anything is written into it. A plain `> "$1"` would
# create it 0644 under the default umask, leaving a setup key or pre-shared key world-readable
# until _commit_tmp chmods it.
_new_private_tmp() {
    rm -f "$1" 2>/dev/null || true
    ( umask 077; : > "$1" ) || return 1
    return 0
}

# Atomic commit: set perms → checkpoint (interruptible) → atomic same-fs rename onto target
# Usage: _commit_tmp <tmp> <target> [chmod mode]
_commit_tmp() {
    local tmp="$1" target="$2" mode="${3:-}"
    if [ -n "$mode" ] && ! chmod "$mode" "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    crit_ck "$tmp"
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}

# ==============================================================================
#  Dependency check
# ==============================================================================
check_deps() {
    local missing=''
    for cmd in curl tar; do
        command -v "$cmd" > /dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -z "$missing" ] && return 0

    msg_err "$(t "Missing required commands:" "缺少必需命令:")$missing"
    case "$OS_TYPE" in
        openwrt) _cmd_hint "opkg update && opkg install$missing" "$(t "install" "安装")" ;;
        debian)  _cmd_hint "apt-get update && apt-get install -y$missing" "$(t "install" "安装")" ;;
        rhel)    _cmd_hint "yum install -y$missing" "$(t "install" "安装")" ;;
        arch)    _cmd_hint "pacman -S --noconfirm$missing" "$(t "install" "安装")" ;;
        alpine)  _cmd_hint "apk add$missing" "$(t "install" "安装")" ;;
        *)       _cmd_hint "<pkg-manager> install$missing" "$(t "install" "安装")" ;;
    esac
    return 1
}

# sha256 helper — coreutils, busybox and openssl all appear in the field
_sha256_of() {
    local f="$1"
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$f" 2>/dev/null | awk '{print $1}'
    elif command -v openssl > /dev/null 2>&1; then
        openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}'
    else
        return 1
    fi
}

# ==============================================================================
#  System & architecture detection
# ==============================================================================
detect_system() {
    if [ -f /etc/openwrt_release ]; then
        OS_TYPE="openwrt"; INIT_SYS="procd"
    elif [ -f /etc/alpine-release ] || \
         (command -v openrc > /dev/null 2>&1 && [ ! -f /etc/debian_version ]); then
        OS_TYPE="alpine"; INIT_SYS="openrc"
    elif [ -f /etc/os-release ]; then
        _id=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        _id_like=$(grep '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"')
        case "$_id $_id_like" in
            *openwrt*)                    OS_TYPE="openwrt"; INIT_SYS="procd"   ;;
            *debian*|*ubuntu*|*raspbian*) OS_TYPE="debian";  INIT_SYS="systemd" ;;
            *fedora*|*rhel*|*centos*|*rocky*|*alma*)
                                          OS_TYPE="rhel";    INIT_SYS="systemd" ;;
            *arch*|*manjaro*)             OS_TYPE="arch";    INIT_SYS="systemd" ;;
            *alpine*)                     OS_TYPE="alpine";  INIT_SYS="openrc"  ;;
            *)                            OS_TYPE="unknown"; INIT_SYS="systemd" ;;
        esac
    else
        OS_TYPE="unknown"; INIT_SYS="unknown"
    fi

    _detect_arch || return 1
    _log "INFO" "Detected: OS=${OS_TYPE} INIT=${INIT_SYS} ARCH=${ARCH_NAME}"
}

# MIPS float ABI. Go's soft-float build runs on hard-float hardware too, so soft-float is the
# safe default and hard-float is only chosen when the kernel clearly reports an FPU.
_mips_hard_float() {
    grep -qi 'fpu.*yes' /proc/cpuinfo 2>/dev/null && return 0
    return 1
}

# Map uname -m onto the upstream release matrix (goreleaser: linux amd64/arm64/arm(v6)/386,
# plus the mips family with an explicit hard/soft float suffix).
_detect_arch() {
    if [ -n "$NB_ARCH" ]; then
        case "$NB_ARCH" in
            amd64|arm64|armv6|386|mips_hardfloat|mips_softfloat|mipsle_hardfloat|mipsle_softfloat|\
mips64_hardfloat|mips64_softfloat|mips64le_hardfloat|mips64le_softfloat)
                ARCH_NAME="$NB_ARCH"; return 0 ;;
            *)
                ARCH_NAME="unknown"
                msg_warn "$(t "Invalid NB_ARCH override: $NB_ARCH" "无效的 NB_ARCH 覆盖值: $NB_ARCH")"
                return 1 ;;
        esac
    fi

    local _machine _fl; _machine=$(uname -m)
    if _mips_hard_float; then _fl="hardfloat"; else _fl="softfloat"; fi

    case "$_machine" in
        x86_64|amd64)                 ARCH_NAME="amd64" ;;
        aarch64|arm64)                ARCH_NAME="arm64" ;;
        # Upstream ships a single armv6 build; it runs on armv6 and armv7 alike.
        armv6l|armv7l|armv7|armv6|arm) ARCH_NAME="armv6" ;;
        i386|i486|i586|i686|x86)      ARCH_NAME="386" ;;
        mips)                         ARCH_NAME="mips_${_fl}" ;;
        mipsel|mipsle)                ARCH_NAME="mipsle_${_fl}" ;;
        mips64)                       ARCH_NAME="mips64_${_fl}" ;;
        mips64el|mips64le)            ARCH_NAME="mips64le_${_fl}" ;;
        *)
            ARCH_NAME="unknown"
            msg_warn "$(t "Unrecognized arch: ${_machine}; NetBird publishes no build for it" \
                          "未识别架构: ${_machine}，NetBird 未提供对应构建")"
            return 1 ;;
    esac
    return 0
}

# Release asset name for a version tag + arch.  netbird_0.78.1_linux_arm64.tar.gz
asset_name() {
    local ver="$1" arch="$2"
    printf 'netbird_%s_linux_%s.tar.gz' "${ver#v}" "$arch"
}

# ==============================================================================
#  Process / service state helpers
# ==============================================================================
_pids_of() {
    if command -v pgrep > /dev/null 2>&1; then
        pgrep -f "${NB_BIN}( |\$)" 2>/dev/null
        return
    fi
    local p cmd
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
        case "$cmd" in *"${NB_BIN} "*) printf '%s\n' "${p##*/}" ;; esac
    done
}
_daemon_running() { [ -n "$(_pids_of)" ]; }

# Run the netbird CLI with the configured daemon socket.
_nb() {
    [ -x "$NB_BIN" ] || return 127
    if [ -n "$NB_DAEMON_ADDR" ]; then
        "$NB_BIN" --daemon-addr "$NB_DAEMON_ADDR" "$@"
    else
        "$NB_BIN" "$@"
    fi
}

installed_version() {
    [ -x "$NB_BIN" ] || return 1
    "$NB_BIN" version 2>/dev/null | head -1 | tr -d '\r'
}

# Wait until the daemon answers on its socket.  $1 = seconds
wait_daemon() {
    local left="${1:-20}"
    while [ "$left" -gt 0 ]; do
        _nb status > /dev/null 2>&1 && return 0
        sleep 1
        left=$((left - 1))
    done
    return 1
}

# `status --check ready` is the client's own health probe (0.7x+). Older builds do not have the
# flag and exit non-zero for the wrong reason, so fall back to reading the human-readable status.
is_connected() {
    _nb status --check ready > /dev/null 2>&1 && return 0
    _nb status 2>/dev/null | grep -qiE '^[[:space:]]*Management:[[:space:]]*Connected'
}

# ==============================================================================
#  Validation helpers
# ==============================================================================
is_valid_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
is_valid_mtu() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1280 ] && [ "$1" -le 9000 ]
}
is_valid_http_url() {
    printf '%s' "$1" | grep -qE '^https?://[A-Za-z0-9._~-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?$'
}
is_valid_ipv4() {
    printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
    local o
    for o in $(printf '%s' "$1" | tr '.' ' '); do
        [ "$o" -le 255 ] || return 1
    done
    return 0
}
is_valid_hostport() {
    local h p
    h=${1%:*}; p=${1##*:}
    [ "$h" != "$1" ] || return 1
    is_valid_ipv4 "$h" || return 1
    is_valid_port "$p"
}
is_valid_iface_name() {
    printf '%s' "$1" | grep -qE '^[A-Za-z][A-Za-z0-9_-]{0,14}$'
}
is_valid_hostname() {
    printf '%s' "$1" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
}
is_valid_version_tag() {
    printf '%s' "$1" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$'
}
# Reject values that would break out of a single argument or smuggle control characters
# into a service file / args file.
is_safe_arg_value() {
    case "$1" in
        *[[:cntrl:]]*) return 1 ;;
        '') return 1 ;;
    esac
    return 0
}
_is_uint() { printf '%s' "$1" | grep -qE '^[0-9]+$'; }
_bool_value() { case "$1" in 1|true|yes|on|y|Y) return 0 ;; *) return 1 ;; esac; }

# systemd needs literal % doubled in ExecStart
_systemd_escape_args() { printf '%s' "$1" | sed 's/%/%%/g'; }

_avail_mb() {
    local dir="$1" out
    [ -d "$dir" ] || dir=$(dirname "$dir")
    out=$(df -k "$dir" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
    [ -n "$out" ] && printf '%s' "$out" || printf '0'
}
_check_space() {
    local dir="$1" need="$2" have
    have=$(_avail_mb "$dir")
    [ "$have" -ge "$need" ] && return 0
    msg_err "$(printf "$(t "Not enough free space in %s: %s MB available, %s MB required" \
                          "%s 可用空间不足: 可用 %s MB，需要 %s MB")" "$dir" "$have" "$need")"
    return 1
}

_warn_ctrl_input() {
    msg_warn "$(t "Value contains control characters and was rejected" "输入含控制字符，已拒绝")"
}

# Prompt for a line of text.  $1 prompt  $2 default
_read_text() {
    local prompt="$1" def="${2:-}" ans=''
    if [ -n "$def" ]; then printf '%s' "$prompt [$def]: "; else printf '%s' "$prompt: "; fi
    IFS= read -r ans || ans=''
    [ -z "$ans" ] && ans="$def"
    printf '%s' "$ans"
}

# Yes/no prompt.  $1 question  $2 default (y|n)
_ask_flag() {
    local q="$1" def="${2:-n}" ans=''
    [ "${NB_NONINTERACTIVE:-0}" = "1" ] && { [ "$def" = y ]; return $?; }
    if [ "$def" = y ]; then printf '%s' "$q [Y/n]: "; else printf '%s' "$q [y/N]: "; fi
    IFS= read -r ans || ans=''
    [ -z "$ans" ] && ans="$def"
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ==============================================================================
#  Service management — unified entry, branching on INIT_SYS
# ==============================================================================
svc_file_path() {
    case "$INIT_SYS" in
        systemd) printf '%s/%s.service' "$NB_SYSTEMD_DIR" "$NB_SERVICE_NAME" ;;
        *)       printf '%s/%s' "$NB_INITD_DIR" "$NB_SERVICE_NAME" ;;
    esac
}

svc_stop() {
    local f; f=$(svc_file_path)
    case "$INIT_SYS" in
        procd)   if [ -x "$f" ]; then "$f" stop 2>/dev/null || true; fi ;;
        systemd) systemctl stop "$NB_SERVICE_NAME" 2>/dev/null || true ;;
        openrc)  rc-service "$NB_SERVICE_NAME" stop 2>/dev/null || true ;;
    esac
}
svc_start() {
    case "$INIT_SYS" in
        procd)   "$(svc_file_path)" enable && "$(svc_file_path)" start ;;
        systemd) systemctl daemon-reload && systemctl enable "$NB_SERVICE_NAME" && systemctl start "$NB_SERVICE_NAME" ;;
        openrc)  rc-update add "$NB_SERVICE_NAME" default 2>/dev/null; rc-service "$NB_SERVICE_NAME" start ;;
        *) return 1 ;;
    esac
}
svc_restart() {
    case "$INIT_SYS" in
        procd)   "$(svc_file_path)" restart ;;
        systemd) systemctl restart "$NB_SERVICE_NAME" ;;
        openrc)  rc-service "$NB_SERVICE_NAME" restart ;;
        *) return 1 ;;
    esac
}
svc_remove() {
    local f; f=$(svc_file_path)
    case "$INIT_SYS" in
        procd)
            [ -f "$f" ] && { "$f" disable 2>/dev/null || true; rm -f "$f"; } ;;
        systemd)
            systemctl disable "$NB_SERVICE_NAME" 2>/dev/null || true
            rm -f "$f"
            systemctl daemon-reload 2>/dev/null || true ;;
        openrc)
            rc-update del "$NB_SERVICE_NAME" default 2>/dev/null || true
            rm -f "$f" ;;
    esac
}

# A service file we did not write (distro package, upstream `netbird service install`) must not be
# silently replaced — the user may be relying on its paths.
svc_foreign() {
    local f; f=$(svc_file_path)
    [ -f "$f" ] || return 1
    grep -q "$NB_MANAGED_MARK" "$f" 2>/dev/null && return 1
    return 0
}

# ==============================================================================
#  Daemon arguments — one argument per line, consumed by every init flavour
# ==============================================================================
write_daemon_args() {
    mkdir -p "$NB_ETC_DIR" 2>/dev/null || true
    local tmp="${NB_DAEMON_ARGS_FILE}.tmp.$$"
    _new_private_tmp "$tmp" || return 1
    {
        printf 'service\nrun\n'
        [ -n "$NB_CONFIG_FILE" ] && printf -- '--config\n%s\n' "$NB_CONFIG_FILE"
        printf -- '--log-level\n%s\n' "$NB_LOG_LEVEL"
        printf -- '--log-file\n%s\n' "$NB_LOG_FILE"
        [ -n "$NB_DAEMON_ADDR" ] && printf -- '--daemon-addr\n%s\n' "$NB_DAEMON_ADDR"
    } >> "$tmp"
    crit_begin
    _commit_tmp "$tmp" "$NB_DAEMON_ARGS_FILE" 644 || { crit_end; return 1; }
    crit_end
    return 0
}

# ==============================================================================
#  Service file writer
# ==============================================================================
svc_write() {
    [ -f "$NB_DAEMON_ARGS_FILE" ] || {
        msg_err "$(t "daemon.args not found" "daemon.args 不存在")"; return 1; }

    local args_line args_line_systemd
    args_line=$(tr '\n' ' ' < "$NB_DAEMON_ARGS_FILE" | sed 's/[[:space:]]*$//')
    args_line_systemd=$(_systemd_escape_args "$args_line")

    case "$INIT_SYS" in procd|systemd|openrc) ;;
        *) msg_warn "$(t "Unknown init system; writing systemd format, adjust manually" \
                         "未知 init 系统，按 systemd 格式写入，请手动调整")"
           INIT_SYS="systemd" ;;
    esac

    [ "$NB_LOG_FILE" = console ] || mkdir -p "$(dirname "$NB_LOG_FILE")" 2>/dev/null || true
    case "$INIT_SYS" in
        systemd) mkdir -p "$NB_SYSTEMD_DIR" 2>/dev/null || true ;;
        *)       mkdir -p "$NB_INITD_DIR"   2>/dev/null || true ;;
    esac

    crit_begin
    case "$INIT_SYS" in

        procd)
            cat > "${NB_INITD_DIR}/${NB_SERVICE_NAME}.tmp.$$" << EOF
#!/bin/sh /etc/rc.common
${NB_MANAGED_MARK}
START=99
STOP=10
USE_PROCD=1
start_service() {
    [ -f ${NB_DAEMON_ARGS_FILE} ] || return 1
    procd_open_instance
    procd_set_param command ${NB_BIN}
    while IFS= read -r _arg; do
        [ -n "\$_arg" ] && procd_append_param command "\$_arg"
    done < ${NB_DAEMON_ARGS_FILE}
    procd_set_param respawn 60 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param limits nofile="65535 65535"
    procd_close_instance
}
service_triggers() {
    procd_add_reload_trigger "${NB_SERVICE_NAME}"
}
EOF
            _commit_tmp "${NB_INITD_DIR}/${NB_SERVICE_NAME}.tmp.$$" "${NB_INITD_DIR}/${NB_SERVICE_NAME}" 755 || {
                crit_end; return 1; }
            ;;

        systemd)
            cat > "${NB_SYSTEMD_DIR}/${NB_SERVICE_NAME}.service.tmp.$$" << EOF
${NB_MANAGED_MARK}
[Unit]
Description=NetBird Client
Documentation=https://docs.netbird.io
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${NB_BIN} ${args_line_systemd}
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
# Deliberately light: the client creates a TUN device, rewrites resolv.conf and programs
# nftables/iptables, so ProtectSystem/ProtectKernelTunables would break it.
NoNewPrivileges=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
            _commit_tmp "${NB_SYSTEMD_DIR}/${NB_SERVICE_NAME}.service.tmp.$$" \
                        "${NB_SYSTEMD_DIR}/${NB_SERVICE_NAME}.service" 644 || { crit_end; return 1; }
            ;;

        openrc)
            cat > "${NB_INITD_DIR}/${NB_SERVICE_NAME}.tmp.$$" << EOF
#!/sbin/openrc-run
${NB_MANAGED_MARK}
description="NetBird Client"
command="${NB_BIN}"
command_args="${args_line}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/netbird.log"
error_log="/var/log/netbird.log"
depend() { need net; after firewall; }
EOF
            _commit_tmp "${NB_INITD_DIR}/${NB_SERVICE_NAME}.tmp.$$" "${NB_INITD_DIR}/${NB_SERVICE_NAME}" 755 || {
                crit_end; return 1; }
            ;;
    esac
    crit_end
    msg_ok "$(t "Service file written" "服务文件已写入")"
    return 0
}

# ==============================================================================
#  GitHub access — mirrors, API, integrity
# ==============================================================================
_mtime() {
    local f="$1"
    date -r "$f" '+%s' 2>/dev/null && return 0
    stat -c %Y "$f" 2>/dev/null && return 0
    printf '0'
}

# One URL per line — _download_urls' caller iterates the result, so a missing newline would
# glue two candidates into a single unusable URL.
_mirror_url() {
    local prefix="$1" url="$2"
    [ -z "$prefix" ] && { printf '%s\n' "$url"; return; }
    printf '%s/%s\n' "${prefix%/}" "$url"
}

# Print the download URLs to try, in order.
_download_urls() {
    local url="$1" p
    if [ -n "$NB_GITHUB_MIRROR" ]; then
        _mirror_url "$NB_GITHUB_MIRROR" "$url"
        printf '%s\n' "$url"
        return
    fi
    printf '%s\n' "$url"
    for p in $NB_GITHUB_MIRRORS; do
        _mirror_url "$p" "$url"
    done
}

_gh_api() {
    local url="$1"
    if [ -n "$NB_GITHUB_TOKEN" ]; then
        curl -fsSL --connect-timeout 10 --max-time 60 \
             -H 'Accept: application/vnd.github+json' \
             -H "Authorization: Bearer ${NB_GITHUB_TOKEN}" "$url" 2>/dev/null
    else
        curl -fsSL --connect-timeout 10 --max-time 60 \
             -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null
    fi
}

# Flatten JSON to one "key":value per line so plain awk/grep can read it reliably.
# The API pretty-prints, so each line also has to be stripped of indentation and of the
# structural [ / { that a nesting level opens with. Values never contain a comma before the
# "body" field, which GitHub emits last.
_json_lines() {
    tr ',' '\n' | sed -e 's/^[[:space:]]*//' \
                      -e 's/^[[{]*//' \
                      -e 's/^[[:space:]]*//' \
                      -e 's/"[[:space:]]*:[[:space:]]*/":/g'
}

# releases → "<tag> <prerelease> <draft>" per line, newest first
_parse_releases() {
    _json_lines | awk '
        /^"tag_name":"/ {
            if (tag != "") { print tag, pre, draft }
            tag = $0; sub(/^"tag_name":"/, "", tag); sub(/".*$/, "", tag)
            pre = "false"; draft = "false"; next
        }
        /^"draft":/      { d = $0; sub(/^"draft":/, "", d);      sub(/[^a-z].*$/, "", d); draft = d; next }
        /^"prerelease":/ { p = $0; sub(/^"prerelease":/, "", p); sub(/[^a-z].*$/, "", p); pre   = p; next }
        END { if (tag != "") print tag, pre, draft }
    '
}

# The sha256 GitHub itself computed for one release asset. Never fetched through a mirror:
# a mirror that can alter the download must not also be the source of the digest.
_release_sha256() {
    local ver="$1" asset="$2" json
    json=$(_gh_api "${NB_GITHUB_DIGEST_API}/repos/${NB_REPO}/releases/tags/${ver}") || return 1
    [ -n "$json" ] || return 1
    printf '%s' "$json" | _json_lines | awk -v want="$asset" '
        index($0, "\"name\":\"" want "\"") { f = 1; next }
        f && /^"digest":"sha256:/ {
            d = $0; sub(/^"digest":"sha256:/, "", d); sub(/[^0-9a-f].*$/, "", d)
            if (length(d) == 64) { print d; exit }
        }
        f && /^"browser_download_url":/ { f = 0 }
    '
}

_verify_sha256() {
    local file="$1" expect="$2" actual
    actual=$(_sha256_of "$file") || {
        msg_warn "$(t "No sha256 tool available (sha256sum/openssl)" "系统缺少 sha256 工具 (sha256sum/openssl)")"
        return 2
    }
    [ -n "$actual" ] || return 2
    if [ "$actual" = "$expect" ]; then
        msg_ok "$(t "SHA-256 verified" "SHA-256 校验通过")"
        return 0
    fi
    msg_err "$(t "SHA-256 mismatch — the download was not what GitHub published" \
                 "SHA-256 不匹配 —— 下载内容与 GitHub 发布的不一致")"
    _log "ERR" "sha256 expected=$expect actual=$actual"
    return 1
}

# ==============================================================================
#  Version selection
# ==============================================================================
_cached_releases() {
    local cache="${CACHE_DIR}/releases.json" now age
    mkdir -p "$CACHE_DIR" 2>/dev/null || true
    if [ "$NB_CACHE_TTL" -gt 0 ] && [ -s "$cache" ]; then
        now=$(date '+%s' 2>/dev/null || printf '0')
        age=$((now - $(_mtime "$cache")))
        if [ "$age" -ge 0 ] && [ "$age" -lt "$NB_CACHE_TTL" ]; then
            cat "$cache"; return 0
        fi
    fi
    local json
    json=$(_gh_api "${NB_GITHUB_API}/repos/${NB_REPO}/releases?per_page=${NB_RELEASES_COUNT}") || return 1
    [ -n "$json" ] || return 1
    ( umask 022; printf '%s' "$json" > "$cache" ) 2>/dev/null || true
    printf '%s' "$json"
}

_version_lookup_failed() {
    msg_err "$(t "Could not reach the GitHub release API" "无法访问 GitHub Release API")"
    msg_info "$(t "Try: NB_GITHUB_TOKEN=<PAT>, NB_GITHUB_MIRROR=<prefix>, or https_proxy=…" \
                  "可尝试: NB_GITHUB_TOKEN=<PAT>、NB_GITHUB_MIRROR=<前缀> 或 https_proxy=…")"
    if [ "$NB_ALLOW_VERSION_FALLBACK" = "1" ] && is_valid_version_tag "$NB_DEFAULT_VERSION"; then
        VER="$NB_DEFAULT_VERSION"
        msg_warn "$(printf "$(t "Falling back to the pinned version %s" "回退到固定版本 %s")" "$VER")"
        return 0
    fi
    msg_info "$(t "Set NB_VERSION=vX.Y.Z to install a specific version without the API." \
                  "可设置 NB_VERSION=vX.Y.Z 以跳过 API 直接安装指定版本。")"
    return 1
}

select_version() {
    if [ -n "${NB_VERSION:-}" ]; then
        is_valid_version_tag "$NB_VERSION" || { msg_err "$(t "Invalid NB_VERSION" "NB_VERSION 格式无效")"; return 1; }
        VER="$NB_VERSION"
        msg_info "$(printf "$(t "Using pinned version %s" "使用指定版本 %s")" "$VER")"
        return 0
    fi

    local json list
    json=$(_cached_releases) || { _version_lookup_failed; return $?; }
    list=$(printf '%s' "$json" | _parse_releases | awk '$3 == "false"')
    [ -n "$list" ] || { _version_lookup_failed; return $?; }

    local latest
    if [ "$NB_ALLOW_PRERELEASE" = "1" ]; then
        latest=$(printf '%s\n' "$list" | awk 'NR==1 {print $1}')
    else
        latest=$(printf '%s\n' "$list" | awk '$2 == "false" {print $1; exit}')
    fi
    [ -n "$latest" ] || { _version_lookup_failed; return $?; }

    if [ "${NB_NONINTERACTIVE:-0}" = "1" ]; then
        VER="$latest"; return 0
    fi

    section "$(t "Choose a version" "选择版本")"
    printf '%s\n' "$list" | awk -v pre="$(t "pre-release" "预发布")" '
        { n = NR; tag = $1; mark = ($2 == "true") ? "  (" pre ")" : ""
          printf "    %2d) %s%s\n", n, tag, mark }' | head -n "$NB_RELEASES_COUNT"
    printf '\n'
    local ans
    ans=$(_read_text "$(t "Number, or a tag like v0.78.1 (Enter = latest ${latest})" \
                          "输入序号，或直接输入版本号如 v0.78.1（回车 = 最新 ${latest}）")" "")
    if [ -z "$ans" ]; then
        VER="$latest"
    elif _is_uint "$ans"; then
        VER=$(printf '%s\n' "$list" | awk -v n="$ans" 'NR == n {print $1}')
        [ -n "$VER" ] || { msg_err "$(t "No such entry" "序号不存在")"; return 1; }
    else
        is_valid_version_tag "$ans" || { msg_err "$(t "Invalid version tag" "版本号格式无效")"; return 1; }
        VER="$ans"
    fi
    msg_ok "$(printf "$(t "Selected %s" "已选择 %s")" "$VER")"
    return 0
}

# ==============================================================================
#  Download, verify, stage
# ==============================================================================
do_download() {
    [ "$ARCH_NAME" = "unknown" ] && { msg_err "$(t "Unsupported architecture" "架构不受支持")"; return 1; }
    ASSET=$(asset_name "$VER" "$ARCH_NAME")

    mkdir -p "$TMP_DIR" || return 1
    _check_space "$TMP_DIR" "$NB_MIN_TMP_MB" || return 1

    local base="https://github.com/${NB_REPO}/releases/download/${VER}/${ASSET}"
    local out="${TMP_DIR}/${ASSET}" url ok=0

    section "$(t "Download" "下载")"
    msg_info "$(printf "$(t "Asset: %s" "文件: %s")" "$ASSET")"

    for url in $(_download_urls "$base"); do
        msg_info "$(printf "$(t "Trying %s" "尝试 %s")" "$url")"
        if curl -fL --connect-timeout 15 --max-time 900 --retry 2 --retry-delay 2 \
                -o "$out" "$url"; then
            ok=1; break
        fi
        rm -f "$out" 2>/dev/null || true
    done
    [ "$ok" = 1 ] || { msg_err "$(t "Download failed from every source" "所有下载源均失败")"; return 1; }
    [ -s "$out" ] || { msg_err "$(t "Downloaded file is empty" "下载文件为空")"; return 1; }

    # ── Integrity ──
    local expect="$NB_SHA256"
    if [ -z "$expect" ]; then
        expect=$(_release_sha256 "$VER" "$ASSET" 2>/dev/null)
    fi
    if [ -n "$expect" ]; then
        _verify_sha256 "$out" "$expect"
        case $? in
            0) ;;
            1) return 1 ;;
            *) [ "$NB_ALLOW_UNVERIFIED" = "1" ] || {
                   msg_err "$(t "Cannot compute a digest; refusing to install (NB_ALLOW_UNVERIFIED=1 overrides)" \
                                "无法计算摘要，拒绝安装（可用 NB_ALLOW_UNVERIFIED=1 强制继续）")"
                   return 1; } ;;
        esac
    else
        msg_warn "$(t "Could not fetch the official digest for this asset" "未能获取该文件的官方摘要")"
        [ "$NB_ALLOW_UNVERIFIED" = "1" ] || {
            msg_err "$(t "Refusing to install an unverified binary (NB_ALLOW_UNVERIFIED=1 overrides)" \
                         "拒绝安装未校验的二进制（可用 NB_ALLOW_UNVERIFIED=1 强制继续）")"
            return 1; }
    fi

    # ── Extract & stage ──
    local ext="${TMP_DIR}/x"
    mkdir -p "$ext" || return 1
    tar -xzf "$out" -C "$ext" 2>/dev/null || {
        msg_err "$(t "Extraction failed" "解压失败")"; return 1; }
    [ -f "${ext}/netbird" ] || { msg_err "$(t "netbird binary not found in the archive" "压缩包中未找到 netbird 可执行文件")"; return 1; }
    chmod 755 "${ext}/netbird" 2>/dev/null || true

    # Run the staged binary before touching the installed one: a wrong-arch download fails here,
    # while the working install is still untouched.
    local sv
    sv=$("${ext}/netbird" version 2>/dev/null | head -1)
    [ -n "$sv" ] || { msg_err "$(t "The downloaded binary does not run on this machine (wrong architecture?)" \
                                   "下载的二进制无法在本机运行（架构不匹配？）")"; return 1; }
    msg_ok "$(printf "$(t "Staged netbird %s" "已暂存 netbird %s")" "$sv")"
    STAGED_BIN="${ext}/netbird"
    return 0
}

# Backup names carry a %Y%m%d%H%M%S stamp, so the glob's lexical order is also chronological:
# the first (total - KEEP) entries are the oldest and are the ones to drop.
_prune_backups() {
    [ "$NB_BACKUP_KEEP" -gt 0 ] || return 0
    local total del f n=0
    set -- "${NB_BIN}".bak.*
    [ -e "$1" ] || return 0            # no matches — the glob stayed literal
    total=$#
    del=$((total - NB_BACKUP_KEEP))
    [ "$del" -gt 0 ] || return 0
    for f in "$@"; do
        n=$((n + 1))
        [ "$n" -le "$del" ] && rm -f "$f" 2>/dev/null
    done
    return 0
}

do_install_bin() {
    [ -n "$STAGED_BIN" ] || { msg_err "$(t "Nothing staged" "没有可安装的文件")"; return 1; }
    mkdir -p "$NB_BIN_DIR" 2>/dev/null || true
    _check_space "$NB_BIN_DIR" "$NB_MIN_BIN_MB" || return 1

    local was_running=0
    _daemon_running && was_running=1
    [ "$was_running" = 1 ] && { msg_info "$(t "Stopping the service to replace the binary" "停止服务以替换二进制")"; svc_stop; sleep 1; }

    crit_begin
    if [ -f "$NB_BIN" ] && [ "$NB_BACKUP_KEEP" -gt 0 ]; then
        cp -f "$NB_BIN" "${NB_BIN}.bak.$(date '+%Y%m%d%H%M%S')" 2>/dev/null || true
    fi
    local tmp="${NB_BIN_DIR}/netbird.tmp.$$"
    if ! cp -f "$STAGED_BIN" "$tmp"; then
        rm -f "$tmp" 2>/dev/null || true; crit_end
        msg_err "$(t "Could not stage the binary into the install directory" "无法将二进制暂存到安装目录")"
        return 1
    fi
    _commit_tmp "$tmp" "$NB_BIN" 755 || { crit_end; msg_err "$(t "Install failed" "安装失败")"; return 1; }
    crit_end
    _prune_backups

    msg_ok "$(printf "$(t "Installed %s → %s" "已安装 %s → %s")" "$(installed_version)" "$NB_BIN")"
    [ "$was_running" = 1 ] && svc_start > /dev/null 2>&1
    return 0
}

# ==============================================================================
#  `netbird up` argument wizard
# ==============================================================================
_derive_dns_domain() {
    [ -n "$NB_DNS_DOMAIN" ] && { printf '%s' "$NB_DNS_DOMAIN"; return; }
    if [ -n "$NB_MANAGEMENT_URL" ]; then printf 'netbird.selfhosted'; else printf 'netbird.cloud'; fi
}

_up_wizard() {
    section "$(t "Connection settings" "连接设置")"

    if [ "${NB_NONINTERACTIVE:-0}" != "1" ]; then
        local ans
        printf '%s\n' "$(t "  1) NetBird Cloud (app.netbird.io)" "  1) NetBird 云服务 (app.netbird.io)")"
        printf '%s\n' "$(t "  2) Self-hosted management server" "  2) 自建管理服务端")"
        printf '\n'
        ans=$(_read_text "$(t "Choice" "请选择")" "1")
        if [ "$ans" = "2" ]; then
            while :; do
                NB_MANAGEMENT_URL=$(_read_text "$(t "Management URL (https://netbird.example.com:443)" \
                                                   "管理端 URL (https://netbird.example.com:443)")" "$NB_MANAGEMENT_URL")
                is_valid_http_url "$NB_MANAGEMENT_URL" && break
                msg_warn "$(t "Not a valid http(s) URL" "不是合法的 http(s) URL")"
            done
            NB_ADMIN_URL=$(_read_text "$(t "Dashboard URL (optional, Enter to skip)" \
                                           "控制台 URL（可选，回车跳过）")" "$NB_ADMIN_URL")
        else
            NB_MANAGEMENT_URL=""
        fi

        printf '\n'
        printf '%s\n' "$(t "  1) Setup key (non-interactive, best for many machines)" \
                          "  1) Setup Key（非交互，适合批量部署）")"
        printf '%s\n' "$(t "  2) Interactive SSO login (opens a URL + code)" \
                          "  2) 交互式 SSO 登录（显示 URL 和验证码）")"
        printf '%s\n' "$(t "  3) Configure only, connect later" "  3) 只写配置，稍后再连接")"
        printf '\n'
        ans=$(_read_text "$(t "Auth method" "认证方式")" "1")
        case "$ans" in
            2) NB_AUTH="sso" ;;
            3) NB_AUTH="none" ;;
            *) NB_AUTH="key"
               if [ -z "$NB_SETUP_KEY" ] && [ -z "$NB_SETUP_KEY_FILE" ]; then
                   NB_SETUP_KEY=$(_read_text "$(t "Setup key" "Setup Key")" "")
               fi ;;
        esac

        NB_HOSTNAME=$(_read_text "$(t "Peer name in the dashboard (Enter = system hostname)" \
                                      "控制台中显示的节点名（回车 = 系统主机名）")" "$NB_HOSTNAME")

        if _ask_flag "$(t "Configure advanced options (interface, ports, routes, DNS, SSH)?" \
                          "是否配置高级选项（接口、端口、路由、DNS、SSH）？")" n; then
            NB_INTERFACE_NAME=$(_read_text "$(t "WireGuard interface name" "WireGuard 接口名")" "$NB_INTERFACE_NAME")
            NB_WIREGUARD_PORT=$(_read_text "$(t "WireGuard port (Enter = default 51820)" \
                                                "WireGuard 端口（回车 = 默认 51820）")" "$NB_WIREGUARD_PORT")
            NB_MTU=$(_read_text "$(t "MTU (Enter = default)" "MTU（回车 = 默认）")" "$NB_MTU")
            _ask_flag "$(t "Act as a routing peer (share this LAN with the mesh)?" \
                           "作为路由节点（把本地网络共享给网络）？")" y || NB_DISABLE_SERVER_ROUTES=1
            _ask_flag "$(t "Accept routes advertised by other peers?" "接受其他节点发布的路由？")" y \
                || NB_DISABLE_CLIENT_ROUTES=1
            _ask_flag "$(t "Let NetBird manage DNS?" "允许 NetBird 管理 DNS？")" y || NB_DISABLE_DNS=1
            _ask_flag "$(t "Enable NetBird's built-in SSH server?" "启用 NetBird 内置 SSH 服务？")" n \
                && NB_ALLOW_SERVER_SSH=1
            _ask_flag "$(t "Enable Rosenpass (post-quantum key exchange)?" "启用 Rosenpass（抗量子密钥交换）？")" n \
                && NB_ENABLE_ROSENPASS=1
        fi
    fi

    # OpenWrt: dnsmasq already owns :53, so pin NetBird's resolver to an alternative port unless
    # DNS management is off or the user pinned an address explicitly.
    if [ "$INIT_SYS" = "procd" ] && [ "$NB_DISABLE_DNS" != "1" ] && \
       [ -z "$NB_DNS_RESOLVER_ADDRESS" ] && [ -z "$_u_resolver" ]; then
        NB_DNS_RESOLVER_ADDRESS="127.0.0.1:5053"
    fi

    # Resolve the auth mode when it was not stated. A key supplied by env means "key"; with no key
    # and no terminal, never fall through to SSO — that would block forever waiting for a browser.
    if [ -z "$NB_AUTH" ]; then
        if [ -n "$NB_SETUP_KEY" ] || [ -n "$NB_SETUP_KEY_FILE" ]; then NB_AUTH="key"
        elif [ "${NB_NONINTERACTIVE:-0}" = "1" ];                 then NB_AUTH="none"
        else                                                           NB_AUTH="sso"
        fi
    fi
    return 0
}

# Validate every value that will end up in up.args, then write the file (0600 — it can hold a
# pre-shared key).  The setup key is deliberately NOT written: it is only needed once, and
# NetBird keeps the resulting identity in config.json.
write_up_args() {
    mkdir -p "$NB_ETC_DIR" 2>/dev/null || true
    local tmp="${NB_UP_ARGS_FILE}.tmp.$$"

    if [ -n "$NB_MANAGEMENT_URL" ] && ! is_valid_http_url "$NB_MANAGEMENT_URL"; then
        msg_err "$(t "Invalid management URL" "管理端 URL 无效")"; return 1; fi
    if [ -n "$NB_ADMIN_URL" ] && ! is_valid_http_url "$NB_ADMIN_URL"; then
        msg_err "$(t "Invalid dashboard URL" "控制台 URL 无效")"; return 1; fi
    if [ -n "$NB_HOSTNAME" ] && ! is_valid_hostname "$NB_HOSTNAME"; then
        msg_err "$(t "Invalid peer name" "节点名无效")"; return 1; fi
    if [ -n "$NB_INTERFACE_NAME" ] && ! is_valid_iface_name "$NB_INTERFACE_NAME"; then
        msg_err "$(t "Invalid interface name" "接口名无效")"; return 1; fi
    if [ -n "$NB_WIREGUARD_PORT" ] && ! is_valid_port "$NB_WIREGUARD_PORT"; then
        msg_err "$(t "Invalid WireGuard port" "WireGuard 端口无效")"; return 1; fi
    if [ -n "$NB_MTU" ] && ! is_valid_mtu "$NB_MTU"; then
        msg_err "$(t "Invalid MTU (1280-9000)" "MTU 无效（1280-9000）")"; return 1; fi
    if [ -n "$NB_DNS_RESOLVER_ADDRESS" ] && ! is_valid_hostport "$NB_DNS_RESOLVER_ADDRESS"; then
        msg_err "$(t "Invalid DNS resolver address (ip:port)" "DNS 解析器地址无效（ip:port）")"; return 1; fi
    if [ -n "$NB_EXTERNAL_IP_MAP" ] && ! is_safe_arg_value "$NB_EXTERNAL_IP_MAP"; then
        _warn_ctrl_input; return 1; fi
    if [ -n "$NB_PRESHARED_KEY" ] && ! is_safe_arg_value "$NB_PRESHARED_KEY"; then
        _warn_ctrl_input; return 1; fi

    _new_private_tmp "$tmp" || return 1
    {
        [ -n "$NB_MANAGEMENT_URL" ]       && printf -- '--management-url\n%s\n' "$NB_MANAGEMENT_URL"
        [ -n "$NB_ADMIN_URL" ]            && printf -- '--admin-url\n%s\n' "$NB_ADMIN_URL"
        [ -n "$NB_PRESHARED_KEY" ]        && printf -- '--preshared-key\n%s\n' "$NB_PRESHARED_KEY"
        [ -n "$NB_HOSTNAME" ]             && printf -- '--hostname\n%s\n' "$NB_HOSTNAME"
        [ -n "$NB_INTERFACE_NAME" ]       && printf -- '--interface-name\n%s\n' "$NB_INTERFACE_NAME"
        [ -n "$NB_WIREGUARD_PORT" ]       && printf -- '--wireguard-port\n%s\n' "$NB_WIREGUARD_PORT"
        [ -n "$NB_MTU" ]                  && printf -- '--mtu\n%s\n' "$NB_MTU"
        [ -n "$NB_DNS_RESOLVER_ADDRESS" ] && printf -- '--dns-resolver-address\n%s\n' "$NB_DNS_RESOLVER_ADDRESS"
        [ -n "$NB_EXTRA_DNS_LABELS" ]     && printf -- '--extra-dns-labels\n%s\n' "$NB_EXTRA_DNS_LABELS"
        [ -n "$NB_EXTRA_IFACE_BLACKLIST" ] && printf -- '--extra-iface-blacklist\n%s\n' "$NB_EXTRA_IFACE_BLACKLIST"
        [ -n "$NB_EXTERNAL_IP_MAP" ]      && printf -- '--external-ip-map\n%s\n' "$NB_EXTERNAL_IP_MAP"
        # a cobra bool flag needs the =value form; "--flag value" would be read as an argument
        [ -n "$NB_NETWORK_MONITOR" ]      && printf -- '--network-monitor=%s\n' \
            "$(_bool_value "$NB_NETWORK_MONITOR" && printf 'true' || printf 'false')"
        _bool_value "$NB_DISABLE_DNS"            && printf -- '--disable-dns\n'
        _bool_value "$NB_DISABLE_CLIENT_ROUTES"  && printf -- '--disable-client-routes\n'
        _bool_value "$NB_DISABLE_SERVER_ROUTES"  && printf -- '--disable-server-routes\n'
        _bool_value "$NB_DISABLE_FIREWALL"       && printf -- '--disable-firewall\n'
        _bool_value "$NB_DISABLE_IPV6"           && printf -- '--disable-ipv6\n'
        _bool_value "$NB_BLOCK_INBOUND"          && printf -- '--block-inbound\n'
        _bool_value "$NB_BLOCK_LAN_ACCESS"       && printf -- '--block-lan-access\n'
        _bool_value "$NB_ALLOW_SERVER_SSH"       && printf -- '--allow-server-ssh\n'
        _bool_value "$NB_ENABLE_ROSENPASS"       && printf -- '--enable-rosenpass\n'
        _bool_value "$NB_ROSENPASS_PERMISSIVE"   && printf -- '--rosenpass-permissive\n'
        [ -n "$NB_CONFIG_FILE" ]                 && printf -- '--config\n%s\n' "$NB_CONFIG_FILE"
        true
    } >> "$tmp"

    crit_begin
    _commit_tmp "$tmp" "$NB_UP_ARGS_FILE" 600 || { crit_end; return 1; }
    crit_end
    msg_ok "$(printf "$(t "Wrote %s" "已写入 %s")" "$NB_UP_ARGS_FILE")"
    return 0
}

# ==============================================================================
#  Connect / disconnect
# ==============================================================================
do_connect() {
    [ -x "$NB_BIN" ] || { msg_err "$(t "netbird is not installed" "netbird 尚未安装")"; return 1; }
    [ "$NB_AUTH" = "none" ] && {
        msg_info "$(t "Configuration written; run this script's 'up' subcommand to connect." \
                      "配置已写入，稍后运行本脚本的 up 子命令即可连接。")"
        return 0; }

    if ! _daemon_running; then
        msg_info "$(t "Starting the NetBird service…" "正在启动 NetBird 服务…")"
        svc_start > /dev/null 2>&1 || true
    fi
    wait_daemon 20 || msg_warn "$(t "The daemon did not answer yet; continuing anyway" "守护进程尚未响应，仍继续尝试")"

    # Build the argument list from up.args (a redirect, not a pipe, so `set --` stays in this shell)
    set --
    if [ -f "$NB_UP_ARGS_FILE" ]; then
        while IFS= read -r _a; do
            [ -n "$_a" ] && set -- "$@" "$_a"
        done < "$NB_UP_ARGS_FILE"
    fi

    local keyfile="" rc=0
    if [ "$NB_AUTH" = "key" ]; then
        if [ -n "$NB_SETUP_KEY_FILE" ]; then
            [ -r "$NB_SETUP_KEY_FILE" ] || { msg_err "$(t "Setup key file is not readable" "Setup Key 文件不可读")"; return 1; }
            keyfile="$NB_SETUP_KEY_FILE"
        else
            [ -n "$NB_SETUP_KEY" ] || { msg_err "$(t "No setup key given" "未提供 Setup Key")"; return 1; }
            mkdir -p "$TMP_DIR" || return 1
            keyfile="${TMP_DIR}/setup.key"
            ( umask 077; printf '%s\n' "$NB_SETUP_KEY" > "$keyfile" ) || return 1
        fi
        # --setup-key-file, not --setup-key: the key never appears in /proc/*/cmdline
        set -- "$@" --setup-key-file "$keyfile"
    else
        set -- "$@" --no-browser
        section "$(t "SSO login" "SSO 登录")"
        msg_info "$(t "Open the URL below in any browser and enter the code shown." \
                      "在任意浏览器中打开下面的地址，并输入显示的验证码。")"
    fi

    _nb up "$@"; rc=$?
    [ -n "$keyfile" ] && [ "$keyfile" != "$NB_SETUP_KEY_FILE" ] && { : > "$keyfile"; rm -f "$keyfile"; }

    if [ "$rc" -ne 0 ]; then
        msg_err "$(t "netbird up failed" "netbird up 执行失败")"
        _cmd_hint "$(_svc_log_cmd recent)" "$(t "check the daemon log" "查看守护进程日志")"
        return 1
    fi
    msg_ok "$(t "Connected" "已连接")"
    return 0
}

do_disconnect() {
    [ -x "$NB_BIN" ] || return 1
    _nb down && msg_ok "$(t "Disconnected" "已断开")"
}

# ==============================================================================
#  OpenWrt integration — DNS forwarding, firewall zone, network interface
# ==============================================================================
_uci_zone_index() {
    local i=0 n
    while n=$(uci -q get "firewall.@zone[$i].name" 2>/dev/null); do
        [ "$n" = "netbird" ] && { printf '%s' "$i"; return 0; }
        i=$((i + 1))
    done
    return 1
}

_uci_forwarding_exists() {
    local src="$1" dst="$2" i=0 s d
    while s=$(uci -q get "firewall.@forwarding[$i].src" 2>/dev/null); do
        d=$(uci -q get "firewall.@forwarding[$i].dest" 2>/dev/null)
        [ "$s" = "$src" ] && [ "$d" = "$dst" ] && return 0
        i=$((i + 1))
    done
    return 1
}

openwrt_dns_setup() {
    command -v uci > /dev/null 2>&1 || { msg_err "$(t "uci not found" "未找到 uci")"; return 1; }
    [ -n "$NB_DNS_RESOLVER_ADDRESS" ] || {
        msg_warn "$(t "No DNS resolver address configured; skipping" "未配置 DNS 解析器地址，跳过")"; return 0; }

    local domain addr port entry
    domain=$(_derive_dns_domain)
    addr=${NB_DNS_RESOLVER_ADDRESS%:*}
    port=${NB_DNS_RESOLVER_ADDRESS##*:}
    entry="/${domain}/${addr}#${port}"

    if uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | tr ' ' '\n' | grep -qx -- "$entry"; then
        msg_info "$(printf "$(t "dnsmasq already forwards %s" "dnsmasq 已转发 %s")" "$domain")"
        return 0
    fi
    uci add_list "dhcp.@dnsmasq[0].server=${entry}" || return 1
    uci commit dhcp || return 1
    /etc/init.d/dnsmasq restart > /dev/null 2>&1 || true
    msg_ok "$(printf "$(t "dnsmasq now forwards %s to %s" "dnsmasq 已将 %s 转发到 %s")" "$domain" "$NB_DNS_RESOLVER_ADDRESS")"
    return 0
}

openwrt_firewall_setup() {
    command -v uci > /dev/null 2>&1 || { msg_err "$(t "uci not found" "未找到 uci")"; return 1; }
    local iface="${NB_INTERFACE_NAME:-wt0}"

    # network interface — proto none, NetBird owns the device
    if [ "$(uci -q get network.netbird 2>/dev/null)" != "interface" ]; then
        uci set network.netbird=interface
        uci set network.netbird.proto='none'
        uci set network.netbird.device="$iface"
        uci commit network
        msg_ok "$(printf "$(t "Network interface 'netbird' bound to %s" "网络接口 netbird 已绑定 %s")" "$iface")"
    else
        uci set network.netbird.device="$iface"
        uci commit network
        msg_info "$(t "Network interface 'netbird' already present" "网络接口 netbird 已存在")"
    fi

    if _uci_zone_index > /dev/null; then
        msg_info "$(t "Firewall zone 'netbird' already present" "防火墙区域 netbird 已存在")"
    else
        uci add firewall zone > /dev/null
        uci set firewall.@zone[-1].name='netbird'
        uci set firewall.@zone[-1].input='ACCEPT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].forward='ACCEPT'
        uci set firewall.@zone[-1].masq='1'
        uci add_list firewall.@zone[-1].network='netbird'
        msg_ok "$(t "Firewall zone 'netbird' created" "已创建防火墙区域 netbird")"
        msg_warn "$(t "The zone accepts all traffic on the tunnel; NetBird access policies are what restrict it." \
                      "该区域放行隧道上的全部流量，实际限制由 NetBird 的访问策略决定。")"
    fi

    if _ask_flag "$(t "Allow LAN → NetBird (local devices reach the mesh)?" \
                      "允许 LAN → NetBird（本地设备访问网络）？")" y; then
        _uci_forwarding_exists lan netbird || {
            uci add firewall forwarding > /dev/null
            uci set firewall.@forwarding[-1].src='lan'
            uci set firewall.@forwarding[-1].dest='netbird'
        }
    fi
    if _ask_flag "$(t "Allow NetBird → LAN (peers reach your local network)?" \
                      "允许 NetBird → LAN（远端节点访问本地网络）？")" y; then
        _uci_forwarding_exists netbird lan || {
            uci add firewall forwarding > /dev/null
            uci set firewall.@forwarding[-1].src='netbird'
            uci set firewall.@forwarding[-1].dest='lan'
        }
    fi
    uci commit firewall || return 1
    /etc/init.d/firewall restart > /dev/null 2>&1 || true
    msg_ok "$(t "Firewall updated" "防火墙已更新")"
    msg_info "$(t "Finally, add this router's LAN subnet as a network resource in the dashboard." \
                  "最后请在控制台把本路由器的局域网网段添加为网络资源。")"
    return 0
}

openwrt_revert() {
    command -v uci > /dev/null 2>&1 || return 0
    local i domain
    domain=$(_derive_dns_domain)
    uci -q delete network.netbird 2>/dev/null && uci commit network
    while i=$(_uci_zone_index); do
        uci -q delete "firewall.@zone[$i]" 2>/dev/null || break
    done
    i=0
    while uci -q get "firewall.@forwarding[$i].src" > /dev/null 2>&1; do
        if [ "$(uci -q get "firewall.@forwarding[$i].src")" = "netbird" ] || \
           [ "$(uci -q get "firewall.@forwarding[$i].dest")" = "netbird" ]; then
            uci -q delete "firewall.@forwarding[$i]"
            continue
        fi
        i=$((i + 1))
    done
    uci commit firewall 2>/dev/null || true
    uci -q del_list "dhcp.@dnsmasq[0].server=/${domain}/${NB_DNS_RESOLVER_ADDRESS%:*}#${NB_DNS_RESOLVER_ADDRESS##*:}" 2>/dev/null
    uci commit dhcp 2>/dev/null || true
    /etc/init.d/firewall restart > /dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart > /dev/null 2>&1 || true
    msg_ok "$(t "OpenWrt network/firewall/DNS entries reverted" "OpenWrt 网络/防火墙/DNS 配置已还原")"
}

openwrt_menu() {
    [ "$INIT_SYS" = "procd" ] || {
        msg_warn "$(t "Router integration is OpenWrt-only" "路由器集成仅适用于 OpenWrt")"; return 0; }
    section "$(t "OpenWrt integration" "OpenWrt 集成")"
    printf '%s\n' "$(t "  1) DNS — forward the NetBird domain through dnsmasq" \
                      "  1) DNS —— 通过 dnsmasq 转发 NetBird 域名")"
    printf '%s\n' "$(t "  2) Firewall — create the netbird zone and forwardings" \
                      "  2) 防火墙 —— 创建 netbird 区域与转发规则")"
    printf '%s\n' "$(t "  3) Both" "  3) 两者都做")"
    printf '%s\n' "$(t "  4) Revert everything this script added" "  4) 还原本脚本添加的全部配置")"
    printf '%s\n' "$(t "  0) Back" "  0) 返回")"
    printf '\n'
    local ans; ans=$(_read_text "$(t "Choice" "请选择")" "0")
    case "$ans" in
        1) openwrt_dns_setup ;;
        2) openwrt_firewall_setup ;;
        3) openwrt_dns_setup; openwrt_firewall_setup ;;
        4) _ask_flag "$(t "Really revert?" "确认还原？")" n && openwrt_revert ;;
        *) return 0 ;;
    esac
}

# ==============================================================================
#  Status
# ==============================================================================
do_status() {
    section "$(t "NetBird status" "NetBird 状态")"

    if [ ! -x "$NB_BIN" ]; then
        msg_err "$(printf "$(t "Not installed (%s missing)" "未安装（缺少 %s）")" "$NB_BIN")"
        return 1
    fi
    printf "  %-22s %s\n" "$(t "Binary" "二进制")"   "$NB_BIN ($(installed_version))"
    printf "  %-22s %s / %s / %s\n" "$(t "Platform" "平台")" "$OS_TYPE" "$INIT_SYS" "$ARCH_NAME"
    printf "  %-22s %s\n" "$(t "Service file" "服务文件")" "$(svc_file_path)"

    if _daemon_running; then
        printf "  %-22s ${C_GRN}%s${C_RST}\n" "$(t "Daemon" "守护进程")" "$(t "running" "运行中")"
    else
        printf "  %-22s ${C_RED}%s${C_RST}\n" "$(t "Daemon" "守护进程")" "$(t "stopped" "已停止")"
        printf '\n'
        _cmd_hint "$(_svc_log_cmd recent)" "$(t "check the log" "查看日志")"
        return 1
    fi

    printf '\n'
    _nb status -d 2>/dev/null | sed 's/^/  /'
    printf '\n'
    _cmd_hint "$(_svc_log_cmd follow)" "$(t "follow the log" "跟踪日志")"
    _cmd_hint "netbird status -d" "$(t "detailed status" "详细状态")"
    is_connected
}

# ==============================================================================
#  Uninstall
# ==============================================================================
do_uninstall() {
    section "$(t "Uninstall" "卸载")"
    _ask_flag "$(t "Remove the NetBird client from this machine?" "确认从本机移除 NetBird 客户端？")" n || return 0

    if [ -x "$NB_BIN" ] && _daemon_running; then
        _nb down > /dev/null 2>&1 || true
    fi
    svc_stop
    svc_remove
    msg_ok "$(t "Service removed" "服务已移除")"

    rm -f "$NB_BIN" 2>/dev/null || true
    if _ask_flag "$(t "Also delete the binary backups?" "同时删除二进制备份？")" y; then
        rm -f "${NB_BIN}".bak.* 2>/dev/null || true
    fi
    msg_ok "$(t "Binary removed" "二进制已删除")"

    if _ask_flag "$(printf "$(t "Delete the configuration in %s? (this deregisters nothing — remove the peer in the dashboard too)" \
                                "删除 %s 中的配置？（这不会注销节点，请同时在控制台删除该 peer）")" "$NB_ETC_DIR")" n; then
        rm -rf "$NB_ETC_DIR" 2>/dev/null || true
        msg_ok "$(t "Configuration deleted" "配置已删除")"
    fi
    if _ask_flag "$(printf "$(t "Delete the client state in %s?" "删除 %s 中的运行状态？")" "$NB_STATE_DIR")" n; then
        rm -rf "$NB_STATE_DIR" 2>/dev/null || true
    fi
    if [ "$INIT_SYS" = "procd" ] && _ask_flag "$(t "Revert the OpenWrt network/firewall/DNS entries?" \
                                                   "还原 OpenWrt 网络/防火墙/DNS 配置？")" n; then
        openwrt_revert
    fi
    msg_ok "$(t "Done" "完成")"
    return 0
}

# ==============================================================================
#  Install flow (menu item 1) — download → service → connect
# ==============================================================================
do_install() {
    check_deps || return 1

    if svc_foreign; then
        msg_warn "$(printf "$(t "%s was not written by this script (package install or 'netbird service install')." \
                                "%s 不是本脚本写入的（可能来自软件包或 netbird service install）。")" "$(svc_file_path)")"
        _ask_flag "$(t "Replace it with a managed service file?" "是否替换为本脚本管理的服务文件？")" n || return 1
    fi

    select_version || return 1
    do_download    || return 1
    do_install_bin || return 1

    write_daemon_args || return 1
    svc_write         || return 1

    _up_wizard      || return 1
    write_up_args   || return 1

    svc_start > /dev/null 2>&1 || msg_warn "$(t "Could not start the service automatically" "未能自动启动服务")"
    do_connect || return 1

    if [ "$INIT_SYS" = "procd" ]; then
        if [ "${NB_NONINTERACTIVE:-0}" = "1" ]; then
            _bool_value "$NB_OPENWRT_DNS"      && openwrt_dns_setup
            _bool_value "$NB_OPENWRT_FIREWALL" && openwrt_firewall_setup
        else
            printf '\n'
            _ask_flag "$(t "Set up dnsmasq forwarding for NetBird DNS?" "是否配置 dnsmasq 转发 NetBird DNS？")" y \
                && openwrt_dns_setup
            _ask_flag "$(t "Set up the firewall so your LAN can use the mesh?" \
                           "是否配置防火墙，使局域网可以使用该网络？")" y \
                && openwrt_firewall_setup
        fi
    fi

    printf '\n'
    do_status > /dev/null 2>&1
    msg_ok "$(t "Installation finished" "安装完成")"
    return 0
}

do_update() {
    check_deps || return 1
    [ -x "$NB_BIN" ] || { msg_err "$(t "netbird is not installed yet" "netbird 尚未安装")"; return 1; }
    msg_info "$(printf "$(t "Installed: %s" "当前版本: %s")" "$(installed_version)")"
    select_version || return 1
    do_download    || return 1
    do_install_bin || return 1
    write_daemon_args || return 1
    svc_write         || return 1
    svc_restart > /dev/null 2>&1 || true
    msg_ok "$(t "Update finished" "更新完成")"
    return 0
}

do_reconfigure() {
    [ -x "$NB_BIN" ] || { msg_err "$(t "netbird is not installed yet" "netbird 尚未安装")"; return 1; }
    _up_wizard    || return 1
    write_up_args || return 1
    write_daemon_args || return 1
    svc_write     || return 1
    svc_restart > /dev/null 2>&1 || true
    do_connect
}

# ==============================================================================
#  Menu
# ==============================================================================
_menu_header() {
    printf '\n'
    printf "${C_BLD}  NetBird Manager v%s${C_RST}  ${C_DIM}%s / %s / %s${C_RST}\n" \
           "$SCRIPT_VERSION" "$OS_TYPE" "$INIT_SYS" "$ARCH_NAME"
    if [ -x "$NB_BIN" ]; then
        if _daemon_running && is_connected; then
            printf "  ${C_GRN}●${C_RST} %s  %s\n" "$(installed_version)" "$(t "connected" "已连接")"
        elif _daemon_running; then
            printf "  ${C_YLW}●${C_RST} %s  %s\n" "$(installed_version)" "$(t "running, not connected" "运行中，未连接")"
        else
            printf "  ${C_RED}●${C_RST} %s  %s\n" "$(installed_version)" "$(t "stopped" "已停止")"
        fi
    else
        printf "  ${C_DIM}○ %s${C_RST}\n" "$(t "not installed" "未安装")"
    fi
    printf '\n'
}

menu() {
    while :; do
        _menu_header
        printf '%s\n' "$(t "  1) Install / update NetBird" "  1) 安装 / 更新 NetBird")"
        printf '%s\n' "$(t "  2) Configure and connect"     "  2) 配置并连接")"
        printf '%s\n' "$(t "  3) Status"                    "  3) 查看状态")"
        printf '%s\n' "$(t "  4) Start / stop / restart"    "  4) 启动 / 停止 / 重启")"
        printf '%s\n' "$(t "  5) Disconnect (netbird down)" "  5) 断开连接 (netbird down)")"
        printf '%s\n' "$(t "  6) OpenWrt integration (DNS / firewall)" "  6) OpenWrt 集成（DNS / 防火墙）")"
        printf '%s\n' "$(t "  7) Log commands"              "  7) 日志命令")"
        printf '%s\n' "$(t "  8) Uninstall"                 "  8) 卸载")"
        printf '%s\n' "$(t "  0) Exit"                      "  0) 退出")"
        printf '\n'
        local ans; ans=$(_read_text "$(t "Choice" "请选择")" "")
        case "$ans" in
            1) if [ -x "$NB_BIN" ]; then do_update; else do_install; fi ;;
            2) do_reconfigure ;;
            3) do_status ;;
            4) svc_menu ;;
            5) do_disconnect ;;
            6) openwrt_menu ;;
            7) section "$(t "Logs" "日志")"
               _cmd_hint "$(_svc_log_cmd follow)" "$(t "follow" "实时跟踪")"
               _cmd_hint "$(_svc_log_cmd recent)" "$(t "recent" "最近记录")"
               _cmd_hint "tail -n 50 $LOG_FILE" "$(t "this script's log" "本脚本日志")" ;;
            8) do_uninstall ;;
            0|q|Q) printf '\n'; exit 0 ;;
            '') continue ;;
            *) msg_warn "$(t "Unknown choice" "无效选项")" ;;
        esac
        printf '\n'
        [ "${NB_NONINTERACTIVE:-0}" = "1" ] && exit 0
        printf '%s' "$(t "Press Enter to continue…" "按回车继续…")"; IFS= read -r _ || exit 0
    done
}

svc_menu() {
    section "$(t "Service" "服务")"
    printf '%s\n' "$(t "  1) Start" "  1) 启动")"
    printf '%s\n' "$(t "  2) Stop"  "  2) 停止")"
    printf '%s\n' "$(t "  3) Restart" "  3) 重启")"
    printf '%s\n' "$(t "  0) Back"  "  0) 返回")"
    printf '\n'
    local ans; ans=$(_read_text "$(t "Choice" "请选择")" "0")
    case "$ans" in
        1) svc_start && msg_ok "$(t "Started" "已启动")" ;;
        2) svc_stop  && msg_ok "$(t "Stopped" "已停止")" ;;
        3) svc_restart && msg_ok "$(t "Restarted" "已重启")" ;;
        *) return 0 ;;
    esac
}

# ==============================================================================
#  Help & entry point
# ==============================================================================
show_help() {
    printf '\n'
    printf "${C_BLD}  NetBird Manager v%s${C_RST}\n\n" "$SCRIPT_VERSION"
    printf '%s\n\n' "$(t "  Usage: sh netbird.sh [subcommand]" "  用法: sh netbird.sh [子命令]")"
    printf '%s\n' "$(t "    (no argument)  open the interactive menu" "    (无参数)       打开交互菜单")"
    printf '%s\n' "$(t "    install        install and connect"       "    install        安装并连接")"
    printf '%s\n' "$(t "    update         update the binary"         "    update         更新二进制")"
    printf '%s\n' "$(t "    up             connect (netbird up)"      "    up             连接 (netbird up)")"
    printf '%s\n' "$(t "    down           disconnect"                "    down           断开连接")"
    printf '%s\n' "$(t "    status         service + network status"  "    status         服务与网络状态")"
    printf '%s\n' "$(t "    start|stop|restart   control the service" "    start|stop|restart   控制服务")"
    printf '%s\n' "$(t "    uninstall      remove NetBird"            "    uninstall      卸载 NetBird")"
    printf '%s\n' "$(t "    version        print script and client versions" "    version        显示脚本与客户端版本")"
    printf '%s\n' "$(t "    help           this help"                 "    help           显示帮助")"
    printf '\n'
    printf '%s\n' "$(t "  Environment variables are documented at the top of this script and in the README." \
                      "  环境变量说明见脚本顶部注释与 README。")"
    printf '\n'
}

show_version() {
    printf '%s\n' "netbird-manager ${SCRIPT_VERSION}"
    if [ -x "$NB_BIN" ]; then
        printf '%s\n' "netbird $(installed_version)"
    else
        printf '%s\n' "$(t "netbird: not installed" "netbird: 未安装")"
    fi
}

main() {
    detect_system || true

    # procd tightening: routers have little flash and a tmpfs /var, so keep one backup and let
    # procd own the log stream instead of writing a rotating file into RAM.
    if [ "$INIT_SYS" = "procd" ]; then
        [ -n "$_u_backup" ]  || NB_BACKUP_KEEP=1
        [ -n "$_u_logfile" ] || NB_LOG_FILE="console"
        [ -n "$_u_logpath" ] || LOG_FILE="/tmp/netbird-manager.log"
    fi

    case "${1:-}" in
        help|-h|--help)  show_help; exit 0 ;;
        version|-v|--version) show_version; exit 0 ;;
    esac

    [ "$(id -u 2>/dev/null || printf 1)" = "0" ] || \
        die "$(t "This script must be run as root (try: sudo sh netbird.sh)" \
                 "本脚本需要 root 权限运行（可用: sudo sh netbird.sh）")"

    _log "INFO" "start v${SCRIPT_VERSION} arg=${1:-menu}"

    case "${1:-}" in
        install)   do_install ;;
        update)    do_update ;;
        up)        do_connect ;;
        down)      do_disconnect ;;
        status)    do_status ;;
        start)     svc_start   && msg_ok "$(t "Started" "已启动")" ;;
        stop)      svc_stop    && msg_ok "$(t "Stopped" "已停止")" ;;
        restart)   svc_restart && msg_ok "$(t "Restarted" "已重启")" ;;
        uninstall) do_uninstall ;;
        '')        if [ "${NB_NONINTERACTIVE:-0}" = "1" ]; then
                       if [ -x "$NB_BIN" ]; then do_update && do_reconfigure; else do_install; fi
                   else
                       menu
                   fi ;;
        *)         msg_err "$(printf "$(t "Unknown subcommand: %s" "未知子命令: %s")" "$1")"
                   show_help; exit 2 ;;
    esac
}

# Sourced by the test suite with NB_SOURCE_ONLY=1 to exercise the pure helpers.
case "${NB_SOURCE_ONLY:-0}" in
    1) : ;;
    *) main "$@" ;;
esac
