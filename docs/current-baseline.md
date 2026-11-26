# 当前基线

本页保留 2026-08-26 完成的生产配置记录，并列出后续脚本策略变化。历史验证不能替代当前服务器检查；服务器专用 IP、域名、邮箱和密钥不进入仓库。

## 2026-09-11 脚本策略变更

- `frps` 连接计数 jail 改为默认关闭，旧 `ENABLE_FRPS=auto` 也关闭；仅显式设置 `1` 才启用。
- FRPS 的 `get a user connection` 包含正常连接，无法证明后端 SSH/RDP 认证失败。显式启用时可通过 `FRPS_FINDTIME`、`FRPS_MAXRETRY`、`FRPS_BANTIME` 调整阈值，但仍有全端口封禁及 `recidive` 影响。
- SSH、FTP 通过 `%(known/ignoreip)s` 保留宝塔白名单，再追加 `::1` 与服务器 `MANUAL_IPS`；其他 jail 防护保持原策略。
- FRP 日志轮转独立于 jail 是否启用，关闭连接计数不会停止已有日志的轮转。
- 增加账号 API Token 的独立动作与运行时凭据读取；没有配置真实 Token 的服务器继续使用原 Global API Key。兼容代码验证不能表述为服务器已切换 Token。
- 部署后需单独验证运行 jail、每项白名单、误封地址及重复执行结果；以下旧的五-jail 记录不代表本次已经部署。

## 共同安装方式

- Fail2Ban 由宝塔插件安装和启停。
- 运行组件为宝塔 Python 环境中的 `1.1.1.dev1`，命令输出版本为 `1.1.1.1`。
- 不安装 Debian/RPM 的第二套 Fail2Ban 软件包。
- 宝塔管理 `/etc/fail2ban/jail.local`、SSH 与 FTP 基础参数。
- 自定义功能由 `/home/Wi-Fi/wifi_fail2ban.sh` 维护。
- SSH 与 FTP 的 `sendmail-whois-lines` 由 `90-wifi.local` 覆盖，仅保留 UFW 动作。

## 上海基线

| jail | 管理方 | 日志 | 动作 |
| --- | --- | --- | --- |
| `sshd` | 宝塔 | `/var/log/auth.log` | UFW |
| `ftpd` | 宝塔 | `/var/log/messages` | UFW |
| `recidive` | 本项目 | `/var/log/fail2ban.log` | UFW |
| `frps` | 本项目 | `/home/Wi-Fi/frps/logs/frps.log` | UFW |
| `vaultwarden` | 本项目 | `/home/Wi-Fi/Bitwarden/data/log/vaultwarden.log` | UFW、Cloudflare |

已验证：

- 五个 jail 同时加载，`fail2ban-client -t` 通过；
- FRP 过滤器可识别当时的用户连接日志，但不能据此认定攻击或认证失败；
- Cloudflare旧凭据接口只读验证成功；
- `/var/log/fail2ban.log` 由运行中进程正常持有；
- 重复执行没有改变 Fail2Ban 进程号或启动时间；
- 宝塔的 `/etc/fail2ban/jail.local` 在扩展前后校验值一致。

## 香港基线

香港曾同时存在 Debian `1.1.0-8`、宝塔 Python 残留和不完整插件目录。2026-08-26 已完成以下清理：

- 通过宝塔卸载登记并停止旧服务；
- 移除 Debian Fail2Ban 软件包和宝塔 Python 残留；
- 将旧配置、数据库和服务文件移入 root 备份；
- 通过宝塔内部官方安装接口安装插件 `2.6`；
- 再次应用统一扩展脚本。

当前运行：

| jail | 管理方 | 日志 | 动作 |
| --- | --- | --- | --- |
| `sshd` | 宝塔 | systemd journal | UFW |
| `ftpd` | 宝塔 | `/var/log/messages` | UFW |
| `recidive` | 本项目 | `/var/log/fail2ban.log` | UFW |

香港没有检测到 FRP 或 Vaultwarden，`90-wifi.local` 因此明确将两项设为 `enabled = false`。Cloudflare 主凭据继续保存在香港，但当前香港 jail 不调用它。

已验证：

- 宝塔插件目录、安装标记、配置文件和服务完整；
- 系统软件包不存在，命令指向宝塔 Python 环境；
- 三个 jail 正常加载且没有邮件动作；
- 日志句柄和日志轮转正常；
- 重复执行不重载服务；
- 宝塔 `jail.local` 与纯净安装快照校验值一致。

## 后续事项

Cloudflare 联动保留旧 Global API Key 兼容方式，并提供指定账号的 API Token 动作。实际切换需安全写入真实 Token、设置账号 ID 和本节点来源标记，再验证权限、规则归属及恢复路径；部署兼容代码本身不会轮换或撤销旧 Key。
