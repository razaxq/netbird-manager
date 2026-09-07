# NetBird Manager

中文 | [English](README.md)

[![ShellCheck](https://github.com/razaxq/netbird-manager/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/razaxq/netbird-manager/actions/workflows/shellcheck.yml)
[![Upstream compatibility](https://github.com/razaxq/netbird-manager/actions/workflows/upstream-compat.yml/badge.svg)](https://github.com/razaxq/netbird-manager/actions/workflows/upstream-compat.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![POSIX sh](https://img.shields.io/badge/shell-POSIX%20sh-blue.svg)](#)

一个用于在 Linux 服务器和路由器上安装、配置与管理 **[NetBird](https://github.com/netbirdio/netbird) 客户端**的交互式脚本。纯 POSIX `sh`，无需 Bash、Python 或其他运行时依赖。

> 第三方脚本，与上游项目无关联。NetBird 二进制的版权归其作者所有。

**语言**：单文件双语，语言选择顺序 —— `NB_LANG` > 系统 locale（`zh*` → 中文）> 英文。

---

## 为什么需要它

NetBird 官方提供 OpenWrt 软件包，但只覆盖 **23.05 及以上**。基于 OpenWrt 21.02 的厂商固件（最典型的就是 GL.iNet）既没有这个包，也没有 `luci-app-netbird` 依赖的 `ucode` 运行时，所以 `opkg install netbird` 只会回答 `Unknown package 'netbird'`。本脚本直接安装官方静态二进制并接管 init 系统，因此同一条命令在 21.02 路由器、Debian VPS 和 Alpine 容器上都能用。

---

## ✨ 功能

- **交互菜单** —— 安装 / 更新 / 配置 / 连接 / 状态 / 卸载，一处搞定
- **三种认证方式** —— Setup Key、交互式 SSO 登录，或"只写配置，稍后再连"；云服务与自建管理端处理方式完全一致
- **覆盖广** —— OpenWrt 与 ImmortalWrt（procd）/ Debian / Ubuntu / RHEL / Arch（systemd）/ Alpine（OpenRC）；支持 amd64、arm64、armv6、386 以及整个 MIPS 家族，浮点 ABI 自动识别
- **非交互模式 + 子命令** —— 全部参数可通过环境变量预设（Ansible / CI）；`status`/`start`/`stop`/`restart`/`up`/`down` 适合放进 cron，失败时返回非零退出码
- **强制完整性校验** —— SHA-256 从 GitHub 官方 Release API 获取并强制比对；支持镜像、代理与 PAT 加速下载，但下载镜像永远不会被当作摘要来源
- **Setup Key 不落盘** —— 通过 `--setup-key-file` 从私有临时目录中的 0600 文件传入，退出时清除，因此既不会出现在 `ps` 输出里，也不会写进任何配置文件
- **事务式安装** —— 先下载校验，暂存后运行 `version` 确认可执行，再用原子重命名提交；`Ctrl+C` 不会留下写了一半的二进制或被截断的服务文件
- **OpenWrt 集成** —— 可一键配置 dnsmasq 对 NetBird DNS 域名的转发、`netbird` 防火墙区域以及 `lan ↔ netbird` 转发，全部幂等且可还原
- **对小闪存友好** —— 安装前检查可用空间；procd 下自动只保留一份备份，并把日志交给 procd，而不是往 tmpfs 里写滚动日志文件

---

## 🚀 快速开始

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/razaxq/netbird-manager@main/netbird.sh -o netbird.sh
sudo sh netbird.sh
```

> 需要 `curl` 与 `tar`；缺少时脚本会打印对应的安装命令。

子命令（执行后退出；不带参数则打开菜单）：

```sh
sh netbird.sh status      # 服务与网络状态；未连接时退出码为 1
sh netbird.sh up          # 连接        (netbird up)
sh netbird.sh down        # 断开        (netbird down)
sh netbird.sh install     # 安装并连接
sh netbird.sh update      # 原地更新二进制
sh netbird.sh start       # 启动 / 停止 / 重启服务
sh netbird.sh uninstall   # 卸载 NetBird
sh netbird.sh version     # 显示脚本与客户端版本
sh netbird.sh help        # 帮助
```

### 在 GL.iNet / OpenWrt 21.02 路由器上

```sh
opkg update && opkg install curl        # BusyBox 的 wget 不支持 HTTPS 重定向
curl -fsSL https://cdn.jsdelivr.net/gh/razaxq/netbird-manager@main/netbird.sh -o /tmp/netbird.sh
sh /tmp/netbird.sh
```

路由器大约需要 **60 MB 空闲闪存**放二进制（`df -h /`），解压过程中还需要约 **110 MB 的 `/tmp` 空间**。两者都会在写入任何文件之前先检查。

---

## ⚙️ 环境变量

### 可直接复制的配置

改好数值后整段执行。这里用 `sudo env` 而不是 `sudo VAR=…`，是因为默认的 sudoers 策略会拒绝在 sudo 命令行上设置的变量。

**用 Setup Key 加入 NetBird 云服务**

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/razaxq/netbird-manager@main/netbird.sh -o netbird.sh
sudo env \
  NB_NONINTERACTIVE=1 \
  NB_AUTH=key \
  NB_SETUP_KEY=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
  NB_HOSTNAME=node-sg-01 \
  sh netbird.sh
```

**加入自建管理端，并作为局域网的路由节点**

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

两段都可以追加的可选项 —— 下载镜像、固定版本，以及改为从文件读取 Key：

```sh
NB_GITHUB_MIRROR=https://ghfast.top \
NB_VERSION=v0.78.1 \
NB_SETUP_KEY_FILE=/root/nb.key \
```

### 连接配置

| 变量 | 说明 | 示例 / 默认值 |
| --- | --- | --- |
| `NB_LANG` | 强制界面语言 | `en` / `zh` |
| `NB_NONINTERACTIVE` | 启用非交互模式 | `1` |
| `NB_AUTH` | 认证方式 | `key` / `sso` / `none` |
| `NB_SETUP_KEY` | Setup Key（不落盘，也不出现在 `argv`） | |
| `NB_SETUP_KEY_FILE` | 改为从文件读取 Setup Key | `/root/nb.key` |
| `NB_MANAGEMENT_URL` | 自建管理端地址；留空即使用 NetBird 云 | `https://nb.example.com:443` |
| `NB_ADMIN_URL` | 自建控制台地址 | 可选 |
| `NB_PRESHARED_KEY` | 自建环境的 WireGuard 预共享密钥 | 可选 |
| `NB_HOSTNAME` | 控制台中显示的节点名 | 系统主机名 |
| `NB_INTERFACE_NAME` | WireGuard 接口名 | `wt0` |
| `NB_WIREGUARD_PORT` | WireGuard 监听端口 | `51820` |
| `NB_MTU` | 接口 MTU（1280-9000） | `1280` |

### 路由、DNS 与安全

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `NB_DNS_RESOLVER_ADDRESS` | NetBird 解析器监听地址（`ip:port`） | procd 下为 `127.0.0.1:5053`，其他为客户端默认 |
| `NB_DISABLE_DNS` | `1` = 完全不接管 DNS | `0` |
| `NB_DISABLE_CLIENT_ROUTES` | `1` = 不接受其他节点发布的路由 | `0` |
| `NB_DISABLE_SERVER_ROUTES` | `1` = 不作为路由节点 | `0` |
| `NB_DISABLE_FIREWALL` | `1` = 不管理防火墙规则 | `0` |
| `NB_DISABLE_IPV6` | `1` = 隧道内禁用 IPv6 | `0` |
| `NB_BLOCK_INBOUND` | `1` = 丢弃所有入站的节点流量 | `0` |
| `NB_BLOCK_LAN_ACCESS` | `1` = 禁止远端节点访问本机所在局域网 | `0` |
| `NB_ALLOW_SERVER_SSH` | `1` = 启用 NetBird 内置 SSH 服务 | `0` |
| `NB_ENABLE_ROSENPASS` / `NB_ROSENPASS_PERMISSIVE` | 抗量子密钥交换 | `0` / `0` |
| `NB_EXTRA_DNS_LABELS` | 额外 DNS 标签，逗号分隔 | 空 |
| `NB_EXTRA_IFACE_BLACKLIST` | 让 NetBird 忽略的网卡 | 空 |
| `NB_EXTERNAL_IP_MAP` | 声明固定外网 IP（NAT 回流场景） | 空 |
| `NB_NETWORK_MONITOR` | `1`/`0` = 网络变化时重建连接 | 客户端默认 |

### OpenWrt 集成

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `NB_OPENWRT_DNS` | `1` = 添加 dnsmasq 对 NetBird 域名的转发条目 | `0` |
| `NB_OPENWRT_FIREWALL` | `1` = 创建 `netbird` 接口、区域及 `lan ↔ netbird` 转发 | `0` |
| `NB_DNS_DOMAIN` | 要转发的域名 | `netbird.cloud`，自建时为 `netbird.selfhosted` |

### 版本与下载

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `NB_VERSION` | 要安装的版本；显式设置即可安装旧版或预发布版 | 最新稳定版 |
| `NB_ARCH` | 覆盖架构识别：`amd64` `arm64` `armv6` `386` `mips_softfloat` `mipsle_hardfloat` `mips64le_softfloat` … | 自动识别 |
| `NB_ALLOW_PRERELEASE` | `1` = 允许自动选中预发布版 | `0` |
| `NB_ALLOW_VERSION_FALLBACK` / `NB_DEFAULT_VERSION` | API 失败时允许回退到固定版本 | `0` / `v0.78.1` |
| `NB_SHA256` | 手动指定压缩包的 SHA-256；否则自动获取官方摘要 | 自动 |
| `NB_ALLOW_UNVERIFIED` | `1` = 无法获取或计算 SHA-256 时仍继续（不推荐） | `0` |
| `NB_GITHUB_MIRROR` | 下载前缀镜像；优先尝试，github.com 作为兜底 | 空 |
| `NB_GITHUB_MIRRORS` | 直连失败后依次尝试的前缀；留空则关闭兜底 | `https://ghfast.top https://gh-proxy.com` |
| `NB_GITHUB_API` / `NB_GITHUB_TOKEN` | API 地址 / PAT（解除每小时 60 次的匿名限制） | 官方 / 空 |
| `NB_CACHE_TTL` | Release 列表缓存秒数（`0` 关闭） | `600` |
| `NB_CACHE_DIR` | Release 列表缓存目录；覆盖时应使用可信的私有父目录 | `/etc/netbird/manager-cache` |
| `NB_MIN_TMP_MB` / `NB_MIN_BIN_MB` | `/tmp` 与安装目录所需的空闲空间 | `110` / `60` |

### 运行与维护

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `NB_LOG_LEVEL` | 守护进程日志级别 | `info` |
| `NB_LOG_FILE` | 守护进程日志目标；`console` 表示交给 procd / journald / OpenRC | procd 下为 `console`，其他为 `/var/log/netbird/client.log` |
| `NB_CONFIG_FILE` | 覆盖客户端配置文件路径。留空 = 使用客户端自身默认值（不同版本位置不同） | 空 |
| `NB_DAEMON_ADDR` | 守护进程套接字 | 客户端默认（`unix:///var/run/netbird.sock`） |
| `NB_BIN_DIR` | 二进制安装目录 | `/usr/bin` |
| `NB_BACKUP_KEEP` | 二进制保留的备份份数（`0` = 不备份） | `3`（procd：`1`） |
| `LOG_FILE` | 脚本自身日志路径 | `/var/log/netbird-manager.log`（procd：`/tmp/…`） |

---

## 📁 文件位置

| 路径 | 说明 |
| --- | --- |
| `/usr/bin/netbird` | 客户端（守护进程与 CLI 是同一个二进制） |
| `/usr/bin/netbird.bak.<时间戳>` | 旧版本备份（按 `NB_BACKUP_KEEP` 轮转） |
| `/etc/netbird/daemon.args` | 服务启动守护进程所用的参数，每行一个 |
| `/etc/netbird/up.args` | 保存的 `netbird up` 选项，权限 0600 —— **绝不包含 Setup Key** |
| `/etc/init.d/netbird` · `/etc/systemd/system/netbird.service` | 服务文件，带 `# managed-by: netbird-manager` 标记 |
| `/var/lib/netbird/` | NetBird 自身写入的运行状态与配置 |
| `/var/log/netbird/client.log` | 守护进程日志（systemd / OpenRC；procd 下走 `logread`） |
| `/var/log/netbird-manager.log` | 脚本自身日志 |

---

## 🧪 开发

欢迎提 Issue 和 PR。本地检查：

```sh
shellcheck -s sh netbird.sh tests/*.sh
sh tests/test_manager.sh           # 离线单元测试
sh tests/test_regressions.sh       # 隔离验证安装、配置和服务管理流程
sh tests/test_upstream_compat.sh   # 需要网络；会真实下载一个 Release 文件
```

CI 会在 `sh`、`dash`、`busybox sh` 下运行 ShellCheck 与单元测试；每周还有一个任务校验上游的架构矩阵、发布摘要与压缩包结构。

更新时会恢复已保存的守护进程配置、socket 和日志设置，显式环境变量优先。连接功能开关以明确的 `true`/`false` 参数保存，重新配置时既能开启也能关闭。服务命令执行失败或守护进程未就绪时会返回失败。OpenWrt 防火墙设置会先重新加载网络配置，再应用区域规则。

在 Git for Windows 下，测试会明确跳过 Unix 文件权限断言；Linux CI 仍会严格检查。若已下载官方客户端，可在运行 `test_regressions.sh` 时设置 `NB_TEST_REAL_BIN=/path/to/netbird`，额外验证密钥文件参数的兼容性；该验证不会连接网络或安装服务。

> ⚠️ 两种语言都写在 `t "en" "zh"` 调用里 —— **改的时候请一起改**。

---

## ❓ 常见问题

**Q：为什么用 `/bin/sh` 而不是 Bash？** 为了兼容 OpenWrt（BusyBox ash）和 Alpine（默认没有 Bash），这样脚本才能在路由器上跑。

**Q：`opkg install netbird` 提示找不到包。** 该软件包只存在于 OpenWrt 23.05 及以上的官方源。基于 21.02 的厂商固件（例如 GL.iNet）没有这个包；`luci-app-netbird` 同样无法支持 21.02，因为那些源里没有 `ucode`。安装官方静态二进制（也就是本脚本做的事）是可行路径。

**Q：下载或 SHA-256 获取失败。** 可用 `NB_GITHUB_MIRROR` 指定下载镜像，或设置 `https_proxy`；API 被限流时设置 `NB_GITHUB_TOKEN`。镜像永远不会被当作摘要来源 —— 摘要始终从 GitHub 官方 API 获取。也可以手动设置 `NB_SHA256`。只有在明确接受风险时才使用 `NB_ALLOW_UNVERIFIED=1`。

**Q：Setup Key 会被保存吗？** 不会。它被写入私有临时目录中的 0600 文件，以 `--setup-key-file` 传给客户端（因此不会出现在 `ps` 里），脚本退出时该文件会被清空并删除。`up.args` 只保存其他选项；节点身份由 NetBird 自己存放在其状态目录中。

**Q：连接后路由器 DNS 不通了。** dnsmasq 已经占用 53 端口，所以 procd 下脚本会把 NetBird 的解析器固定到 `127.0.0.1:5053`，并询问是否添加对应的 dnsmasq 转发条目。如果当时跳过了，再运行一次脚本选择 **OpenWrt 集成 → DNS**；或者设置 `NB_DISABLE_DNS=1` 完全不接管 DNS。

**Q：能在 LuCI 里配置 `wt0` 吗？** 不能。该接口及其密钥由 NetBird 完全管理。脚本的防火墙集成把 `wt0` 以 `proto none` 加入网络配置，正是为了让防火墙能引用它，而不需要任何人去配置它。

**Q：升级固件后 NetBird 还在吗？** sysupgrade 会清空 `/usr/bin`，二进制会丢失，需要重新运行脚本安装。`/etc/netbird` 下的配置在它位于 sysupgrade 备份列表中时可以保留；`/var/lib/netbird` 里的节点身份通常不会保留，所以要做好重新认证的准备。

**Q：卸载会删掉配置和节点身份吗？** 不会自动删。卸载流程会**分别**询问备份、`/etc/netbird`、`/var/lib/netbird` 以及 OpenWrt 的网络/防火墙/DNS 配置，默认全部保留。在 NetBird 控制台中删除该 peer 是另外一步。

---

[MIT](LICENSE) © 2026 Ramos
