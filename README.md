# NetBird Manager

[中文说明](README_zh.md) | English

[![ShellCheck](https://github.com/razaxq/netbird-manager/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/razaxq/netbird-manager/actions/workflows/shellcheck.yml)
[![Upstream compatibility](https://github.com/razaxq/netbird-manager/actions/workflows/upstream-compat.yml/badge.svg)](https://github.com/razaxq/netbird-manager/actions/workflows/upstream-compat.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![POSIX sh](https://img.shields.io/badge/shell-POSIX%20sh-blue.svg)](#)

An interactive script to **install, configure and manage the [NetBird](https://github.com/netbirdio/netbird) client** on Linux servers and on routers. Pure POSIX `sh` — no Bash, Python or other runtime dependency.

> A third-party script, not affiliated with the upstream project. NetBird binaries remain the copyright of their authors.

**Language**: the single script is bilingual and picks its language in this order — `NB_LANG` > system locale (`zh*` → Chinese) > English.

---

## Why this exists

NetBird ships an OpenWrt package, but only for **23.05 and newer**. Vendor firmware based on OpenWrt 21.02 — GL.iNet's, most notably — has neither the package nor the `ucode` runtime that `luci-app-netbird` needs, so `opkg install netbird` just answers `Unknown package 'netbird'`. This script installs the official static binary directly and wires up the init system, so the same command works on a 21.02 router, a Debian VPS and an Alpine container.

---

## ✨ Features

- **Interactive menu** — install / update / configure / connect / status / uninstall in one place
- **Three auth paths** — setup key, interactive SSO login, or "configure only, connect later"; cloud and self-hosted management servers are treated identically
- **Broad coverage** — OpenWrt & ImmortalWrt (procd) / Debian / Ubuntu / RHEL / Arch (systemd) / Alpine (OpenRC); amd64, arm64, armv6, 386 and the whole MIPS family with automatic float-ABI detection
- **Non-interactive mode + subcommands** — preset every parameter through environment variables (Ansible / CI); `status`/`start`/`stop`/`restart`/`up`/`down` suit cron and return a non-zero exit code on failure
- **Mandatory integrity check** — the SHA-256 is fetched from the official GitHub release API and enforced; mirrors, proxies and a PAT are supported for speed, but a download mirror is never trusted as the source of the digest
- **The setup key never touches disk** — it is passed via `--setup-key-file` from a 0600 file in a private temp dir that is wiped on exit, so it appears neither in `ps` output nor in any config file
- **Transactional installs** — download and verify first, stage the binary and run its `version` before touching the live one, then commit with an atomic rename; `Ctrl+C` never leaves a half-written binary or a truncated service file
- **OpenWrt integration** — optional one-command setup of dnsmasq forwarding for the NetBird DNS domain, the `netbird` firewall zone, and `lan ↔ netbird` forwarding, all idempotent and revertible
- **Small-flash friendly** — free space is checked before installing; under procd the script keeps one backup and lets procd own the log stream instead of writing a rotating file into a tmpfs

---

## 🚀 Quick start

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/razaxq/netbird-manager@main/netbird.sh -o netbird.sh
sudo sh netbird.sh
```

> Requires `curl` and `tar`; the script prints the matching install command if either is missing.

Subcommands (run and exit; no argument opens the menu):

```sh
sh netbird.sh status      # service + network status; exit 1 when not connected
sh netbird.sh up          # connect        (netbird up)
sh netbird.sh down        # disconnect     (netbird down)
sh netbird.sh install     # install and connect
sh netbird.sh update      # update the binary in place
sh netbird.sh start       # start / stop / restart the service
sh netbird.sh uninstall   # remove NetBird
sh netbird.sh version     # print the script and client versions
sh netbird.sh help        # help
```

### On a GL.iNet / OpenWrt 21.02 router

```sh
opkg update && opkg install curl        # BusyBox wget cannot do HTTPS redirects
curl -fsSL https://cdn.jsdelivr.net/gh/razaxq/netbird-manager@main/netbird.sh -o /tmp/netbird.sh
sh /tmp/netbird.sh
```

The router needs roughly **60 MB of free flash** for the binary (`df -h /`) and about **110 MB of free `/tmp`** while extracting. Both are checked before anything is written.

---

## ⚙️ Environment variables

### Copy-paste configuration

Edit the values, then run the whole block. `sudo env` is used rather than `sudo VAR=…` because the default sudoers policy refuses variables set on the sudo command line.

**Join NetBird Cloud with a setup key**

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/razaxq/netbird-manager@main/netbird.sh -o netbird.sh
sudo env \
  NB_NONINTERACTIVE=1 \
  NB_AUTH=key \
  NB_SETUP_KEY=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
  NB_HOSTNAME=node-sg-01 \
  sh netbird.sh
```

**Join a self-hosted management server, as a routing peer for the LAN**

```sh
sudo env \
  NB_NONINTERACTIVE=1 \
  NB_AUTH=key \
  NB_SETUP_KEY=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
  NB_MANAGEMENT_URL=https://netbird.example.com:443 \
  NB_HOSTNAME=router-hq \
  NB_OPENWRT_DNS=1 \
  NB_OPENWRT_FIREWALL=1 \
  sh netbird.sh
```

Optional additions to either block — a download mirror, a pinned version, and reading the key from a file instead:

```sh
NB_GITHUB_MIRROR=https://ghfast.top \
NB_VERSION=v0.78.1 \
NB_SETUP_KEY_FILE=/root/nb.key \
```

### Connection

| Variable | Description | Example / default |
| --- | --- | --- |
| `NB_LANG` | Force the interface language | `en` / `zh` |
| `NB_NONINTERACTIVE` | Enable non-interactive mode | `1` |
| `NB_AUTH` | Auth mode | `key` / `sso` / `none` |
| `NB_SETUP_KEY` | Setup key (never written to disk, never in `argv`) | |
| `NB_SETUP_KEY_FILE` | Read the setup key from a file instead | `/root/nb.key` |
| `NB_MANAGEMENT_URL` | Self-hosted management server; empty = NetBird Cloud | `https://nb.example.com:443` |
| `NB_ADMIN_URL` | Self-hosted dashboard URL | optional |
| `NB_PRESHARED_KEY` | Self-hosted WireGuard pre-shared key | optional |
| `NB_HOSTNAME` | Peer name shown in the dashboard | system hostname |
| `NB_INTERFACE_NAME` | WireGuard interface name | `wt0` |
| `NB_WIREGUARD_PORT` | WireGuard listen port | `51820` |
| `NB_MTU` | Interface MTU (1280-9000) | `1280` |

### Routing, DNS and security

| Variable | Description | Default |
| --- | --- | --- |
| `NB_DNS_RESOLVER_ADDRESS` | Bind address for NetBird's resolver (`ip:port`) | `127.0.0.1:5053` under procd, else the client default |
| `NB_DISABLE_DNS` | `1` = do not manage DNS at all | `0` |
| `NB_DISABLE_CLIENT_ROUTES` | `1` = do not accept routes from other peers | `0` |
| `NB_DISABLE_SERVER_ROUTES` | `1` = do not act as a routing peer | `0` |
| `NB_DISABLE_FIREWALL` | `1` = do not manage firewall rules | `0` |
| `NB_DISABLE_IPV6` | `1` = disable IPv6 inside the tunnel | `0` |
| `NB_BLOCK_INBOUND` | `1` = drop all inbound peer traffic | `0` |
| `NB_BLOCK_LAN_ACCESS` | `1` = block peers from reaching this host's LAN | `0` |
| `NB_ALLOW_SERVER_SSH` | `1` = enable NetBird's built-in SSH server | `0` |
| `NB_ENABLE_ROSENPASS` / `NB_ROSENPASS_PERMISSIVE` | Post-quantum key exchange | `0` / `0` |
| `NB_EXTRA_DNS_LABELS` | Extra DNS labels, comma-separated | empty |
| `NB_EXTRA_IFACE_BLACKLIST` | Interfaces NetBird should ignore | empty |
| `NB_EXTERNAL_IP_MAP` | Advertise a fixed external IP (NAT hairpin) | empty |
| `NB_NETWORK_MONITOR` | `1`/`0` = restart the connection on network changes | client default |

### OpenWrt integration

| Variable | Description | Default |
| --- | --- | --- |
| `NB_OPENWRT_DNS` | `1` = add the dnsmasq forwarding entry for the NetBird domain | `0` |
| `NB_OPENWRT_FIREWALL` | `1` = create the `netbird` interface, zone and `lan ↔ netbird` forwarding | `0` |
| `NB_DNS_DOMAIN` | Domain to forward | `netbird.cloud`, or `netbird.selfhosted` when self-hosting |

### Version and download

| Variable | Description | Default |
| --- | --- | --- |
| `NB_VERSION` | Version to install; setting it explicitly allows an older or pre-release version | latest stable |
| `NB_ARCH` | Override arch detection: `amd64` `arm64` `armv6` `386` `mips_softfloat` `mipsle_hardfloat` `mips64le_softfloat` … | auto-detected |
| `NB_ALLOW_PRERELEASE` | `1` = let a pre-release be selected automatically | `0` |
| `NB_ALLOW_VERSION_FALLBACK` / `NB_DEFAULT_VERSION` | Allow falling back to a fixed version when the API fails | `0` / `v0.78.1` |
| `NB_SHA256` | Set the tarball's SHA-256 manually; otherwise the official digest is fetched | automatic |
| `NB_ALLOW_UNVERIFIED` | `1` = continue when the SHA-256 cannot be fetched or computed (not recommended) | `0` |
| `NB_GITHUB_MIRROR` | Download prefix mirror; tried first, with github.com as the last resort | empty |
| `NB_GITHUB_MIRRORS` | Fallback prefixes tried in order after a direct attempt fails; empty disables the fallback | `https://ghfast.top https://gh-proxy.com` |
| `NB_GITHUB_API` / `NB_GITHUB_TOKEN` | API base / PAT (lifts the 60-per-hour anonymous limit) | official / empty |
| `NB_CACHE_TTL` | Seconds to cache the release list (`0` disables) | `600` |
| `NB_MIN_TMP_MB` / `NB_MIN_BIN_MB` | Free space required in `/tmp` and in the install directory | `110` / `60` |

### Runtime and maintenance

| Variable | Description | Default |
| --- | --- | --- |
| `NB_LOG_LEVEL` | Daemon log level | `info` |
| `NB_LOG_FILE` | Daemon log target; `console` routes it to procd / journald / OpenRC | `console` under procd, else `/var/log/netbird/client.log` |
| `NB_CONFIG_FILE` | Override the client profile path. Empty = the client's own default, which moved between releases | empty |
| `NB_DAEMON_ADDR` | Daemon socket | client default (`unix:///var/run/netbird.sock`) |
| `NB_BIN_DIR` | Where the binary is installed | `/usr/bin` |
| `NB_BACKUP_KEEP` | Backups kept for the binary (`0` = no backup) | `3` (procd: `1`) |
| `LOG_FILE` | Path of the script's own log | `/var/log/netbird-manager.log` (procd: `/tmp/…`) |

---

## 📁 File locations

| Path | Description |
| --- | --- |
| `/usr/bin/netbird` | The client (daemon and CLI are the same binary) |
| `/usr/bin/netbird.bak.<ts>` | Old-version backups (rotated by `NB_BACKUP_KEEP`) |
| `/etc/netbird/daemon.args` | Arguments the service starts the daemon with, one per line |
| `/etc/netbird/up.args` | Saved `netbird up` options, mode 0600 — **never contains the setup key** |
| `/etc/init.d/netbird` · `/etc/systemd/system/netbird.service` | Service file, tagged `# managed-by: netbird-manager` |
| `/var/lib/netbird/` | Client state and profile written by NetBird itself |
| `/var/log/netbird/client.log` | Daemon log (systemd / OpenRC; under procd it goes to `logread`) |
| `/var/log/netbird-manager.log` | The script's own log |

---

## 🧪 Development

Issues and PRs are welcome. Local checks:

```sh
shellcheck -s sh netbird.sh tests/*.sh
sh tests/test_manager.sh           # offline unit tests
sh tests/test_upstream_compat.sh   # needs network; downloads one real release asset
```

CI runs ShellCheck and the unit tests under `sh`, `dash` and `busybox sh`; a weekly job verifies the upstream release matrix, the published digests and the archive layout.

> ⚠️ Both languages are inlined in `t "en" "zh"` calls — **change them together**.

---

## ❓ FAQ

**Q: Why `/bin/sh` instead of Bash?** To stay compatible with OpenWrt (BusyBox ash) and Alpine (no Bash by default), so the script also runs on routers.

**Q: `opkg install netbird` says the package is unknown.** The package only exists in the OpenWrt 23.05+ feeds. Vendor firmware built on 21.02 — GL.iNet's, for example — has no such package, and `luci-app-netbird` cannot support 21.02 either because those feeds have no `ucode`. Installing the official static binary, which is what this script does, is the way in.

**Q: The download or the SHA-256 lookup fails.** Use `NB_GITHUB_MIRROR` for a download mirror or set `https_proxy`; set `NB_GITHUB_TOKEN` when the API is rate-limited. A mirror is never trusted as the digest source — the script still fetches the SHA-256 from the official GitHub API. You can also set `NB_SHA256` by hand. Use `NB_ALLOW_UNVERIFIED=1` only if you explicitly accept the risk.

**Q: Is the setup key stored anywhere?** No. It is written to a 0600 file in a private temp directory, passed to the client as `--setup-key-file` so it never appears in `ps`, and the file is truncated and deleted when the script exits. `up.args` holds the other options; NetBird keeps the resulting peer identity in its own state directory.

**Q: DNS stops working on my router after connecting.** dnsmasq already owns port 53, so under procd the script pins NetBird's resolver to `127.0.0.1:5053` and offers to add the matching dnsmasq forwarding entry. If you skipped that step, run the script again and pick **OpenWrt integration → DNS**, or set `NB_DISABLE_DNS=1` to leave DNS alone entirely.

**Q: Can I configure `wt0` in LuCI?** No. NetBird creates and fully manages that interface and its keys. The script's firewall integration adds `wt0` to the network config as `proto none` precisely so the firewall can reference it without anyone trying to configure it.

**Q: Does a firmware upgrade keep NetBird?** A sysupgrade wipes `/usr/bin`, so the binary is gone and has to be reinstalled — run the script again. Configuration under `/etc/netbird` survives if it is in your sysupgrade backup list; the peer identity in `/var/lib/netbird` usually does not, so plan on re-authenticating.

**Q: Does uninstalling delete my config and node identity?** Not automatically. The uninstall flow asks **separately** about the backups, `/etc/netbird`, `/var/lib/netbird` and the OpenWrt network/firewall/DNS entries, and keeps everything by default. Removing the peer from the NetBird dashboard is a separate step.

---

[MIT](LICENSE) © 2026 Ramos
