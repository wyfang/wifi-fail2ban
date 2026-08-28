# 安全与凭据

## 不进入仓库的内容

- Cloudflare 邮箱、Global API Key 或 API Token；
- 管理 IP、服务器公网 IP 和内部域名；
- Fail2Ban SQLite 数据库、当前封禁名单和 iptables/ipset 快照；
- FRP、Vaultwarden、SSH、FTP 和 Fail2Ban 日志；
- `/root/fail2ban-backups` 中的任何备份。
- `/root/.config/wifi-fail2ban/deployment.env` 中的真实管理地址和服务器专用设置。

`.gitignore` 只减少误提交风险，不能替代提交前检查。

## Cloudflare 凭据

当前兼容配置读取：

```text
/root/.config/wifi-fail2ban/cloudflare.credentials
```

格式：

```text
CF_EMAIL=admin@example.com
CF_KEY=replace-with-a-secret-value
```

权限必须是 `root:root`、`600`；父目录必须是 `root:root`、`700`。脚本必须是 `root:root`、`700`，不得属于 Web 服务用户。

同目录中的 `deployment.env` 也必须是 `root:root`、`600`。脚本只解析允许的键，不会将该文件作为 shell 脚本执行。

当前 `CF_KEY` 兼容 Cloudflare旧 Global API Key。Global API Key 权限过大，应迁移到只允许管理必要 IP Access Rules 的 API Token。完成迁移前，不要把 `CF_KEY` 简单替换成 Token，因为两种动作的认证头和参数不同。

## 日志权限

Fail2Ban 以 root 读取应用日志，因此部署脚本不得把 FRP 或 Vaultwarden 日志改成 `www` 或其他固定用户。日志轮转采用 `copytruncate`，保持应用当前文件属主。

`/var/log/fail2ban.log` 使用 `root:adm`、`0640`，并由 tmpfiles 和 logrotate 确保重启及轮转后仍存在。

## 配置审查

提交前至少检查：

```bash
git diff --check
git grep -n -E 'CF_KEY=.{20}|cftoken="[^"]{20}|([0-9]{1,3}\.){3}[0-9]{1,3}'
```

示例地址可能被上述检查命中，应人工确认它们来自 RFC 5737 的文档网段，而不是真实服务器地址。
