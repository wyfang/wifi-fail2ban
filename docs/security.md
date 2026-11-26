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

凭据主副本以香港服务器上的文件为准，不要求在密码管理器另存一份：

```text
hongkong:/root/.config/wifi-fail2ban/cloudflare.credentials
```

其他服务器经 SSH 从香港安全取得运行副本，保存到各自的 `/root/.config/wifi-fail2ban/cloudflare.credentials`。本节规定保存位置与通用使用方式，不代表真实 Token 已创建或服务器已切换认证。

Token 模式文件包含以下两个字段；示例只展示格式，不是真实凭据：

```text
CF_API_TOKEN=replace-with-an-account-scoped-api-token
CF_ACCOUNT_ID=00000000000000000000000000000000
```

在 Cloudflare 创建自定义 Token，选择账号级 **Account Firewall Access Rules Edit** 权限（API 参考名称为 `Account Firewall Access Rules Write`），资源限制到指定账号。`CF_ACCOUNT_ID` 填账号 ID，不是 Zone ID。账号级 IP Access Rules 会影响该账号的所有适用站点，不能描述成只保护某一个域名。

每台调用 Token 动作的服务器还需在自身 `deployment.env` 配置稳定、唯一的 `CF_RULE_OWNER`，例如 `node-one`。来源标记不是秘密，不应复用其他节点的值。它与 jail 名共同组成 `Wi-Fi Fail2Ban <owner> <jail>` 的精确规则备注，防止多个节点互相解封。

兼容的旧 Global API Key 格式：

```text
CF_EMAIL=admin@example.com
CF_KEY=replace-with-a-secret-value
```

主副本与各节点运行副本必须是 `root:root`、`600` 的普通文件，不使用符号链接；父目录必须是 `root:root`、`700`。脚本必须是 `root:root`、`700`，不得属于 Web 服务用户。每次切换的旧凭据和配置只保存在服务器 root 受限备份目录，目录权限 `700`、文件权限 `600`。

同目录中的 `deployment.env` 也必须是 `root:root`、`600`，但它由每台服务器独立维护，不随共享凭据分发。脚本只解析允许的键，不会将该文件作为 shell 脚本执行。

`CF_KEY` 使用旧 Global API Key 的 `X-Auth-Email`/`X-Auth-Key` 认证；它不是使用 `X-Auth-User-Service-Key` 的 Origin CA Service Key。Origin CA Service Key 的退役不能直接当作当前 Fail2Ban Global API Key 已失效的证据。不要把 `CF_KEY` 的值简单换成 Token，两者的认证头、作用范围和动作不同。

Token 模式使用独立 `wifi-cloudflare` 动作和 Python 标准库辅助程序，以 `Authorization: Bearer` 调用 `/accounts/{account_id}/firewall/access_rules/rules`。Token 只在运行时从属主为 root、权限为 `400` 或 `600` 的普通文件读取，不展开到 jail 配置、命令参数或日志；拒绝重定向，保留系统 TLS 验证。支持包存在时，任何凭据格式都先由辅助程序严格解析；字段拼错、前导空白、重复或多余字段都会报错。缺少支持包时只接受明确合法的旧格式。新 Token 字段存在时优先使用 Token，参数无效或 API 失败不会静默退回权限更大的旧 Key。

`check` 只 GET 指定账号的规则列表，能够证明读取权限；它不会创建测试封禁，也不能单独证明写权限已验证。API 创建或删除返回失败时，动作以失败状态退出，不打印令牌、认证头或原始响应正文。

### 迁移与规则归属

先保存旧配置和相关规则清单，再安装兼容代码。新 Token 与账号 ID 只写入香港主副本同目录的 `cloudflare.credentials.new` 候选文件，设置为 root 专用普通文件，并设置本节点 `CF_RULE_OWNER`。确认候选 GET 检查通过、staged Fail2Ban 配置有效后，创建受限备份，将 `.new` 在同目录原子重命名为正式文件，再应用并验证动作。其他节点从香港取得候选副本后，也先验证、备份，再原子切换；具体命令见 [香港分发流程](./distribution.md)。尚未填写真实 Token 并完成实机验证时，只能说明代码具备兼容能力。

新动作只删除 IP、类型、`mode=block` 和完整来源备注都一致的记录；删除前再次读取对应规则核对归属。它不会认领或删除手工规则、其他节点/jail 的规则，或旧原生动作留下的 `Fail2Ban <jail>` 记录。遇到同 IP 的非本动作 block 时会报冲突并保留，需单独核实来源；旧规则迁移不能通过按 IP 全量删除完成。

同一个账号 Token 可以供多个节点运行，每个节点仍需使用唯一的 `CF_RULE_OWNER`。备注是动作保留的命名空间，不是不可伪造的身份凭据。来源标记防止误删，不能替代多个节点对同一 IP 的共享封禁状态管理；需要多个写入方共同维护同一账号/IP 时，应另行设计协调机制。

轮换 Token 时，以香港主副本发起并同步所有使用方，逐个验证节点后再决定是否撤销旧 Token。由旧 Key 迁移时同样先完成真实读写与回退验证、核对其他使用方，再决定是否移除或撤销旧 Key；脚本不会自动轮换或撤销任何凭据。

官方接口与权限参考：[创建账号 IP Access Rule](https://developers.cloudflare.com/api/resources/firewall/subresources/access_rules/methods/create/)。

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
