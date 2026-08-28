# 项目维护指令

## 管理边界

- 宝塔 Fail2Ban 插件拥有 `/etc/fail2ban/jail.local`，不得由本项目覆盖或重写。
- 本项目只维护带 `wifi-` 前缀的过滤器、日志策略，以及
  `/etc/fail2ban/jail.d/90-wifi.local`。
- 宝塔支持的安装、卸载、启停和基础 jail 设置优先通过面板完成。
- 宝塔不支持的高级功能可以由脚本维护，但必须保持为独立文件，并在文档中说明。

## 安全要求

- 不得提交真实 IP、域名、邮箱、Cloudflare 凭据、日志、封禁数据库或服务器备份。
- Cloudflare 凭据只能从 root 可读文件或运行时环境读取，不能写入脚本。
- 不得默认删除 `/var/lib/fail2ban/fail2ban.sqlite3`、清空封禁状态或停止服务。
- 不得修改 FRP、Vaultwarden 等应用日志的属主。
- 配置必须先在临时副本中通过 `fail2ban-client -t`，再写入正式目录。

## 可重复执行

- 脚本重复运行时不得追加重复 jail、动作或日志轮转条目。
- 内容没有变化时不得重载或重启 Fail2Ban。
- 新增文件使用明确且唯一的名称，避免覆盖发行版或宝塔文件。

## 多服务器分发

- 本地 Git 仓库是脚本和文档的权威来源。
- SSH 别名 `hongkong` 的 root 分发目录保存已校验脚本和 Cloudflare 主凭据。
- 先从 Git 更新香港脚本，再由香港同步到其他服务器；不要反向把服务器脚本覆盖回 Git。
- 真实凭据只允许在服务器间安全复制，不得经过标准输出、聊天或 Git。

## 验证

- 修改脚本后至少运行 `bash -n scripts/wifi_fail2ban.sh` 和
  `bash -n scripts/audit_fail2ban.sh`。
- 修改规则后核对 `docs/rules.md` 与 `docs/current-baseline.md`。
- 涉及生产部署时，验证配置、jail 列表、日志路径、动作名称和重复执行结果。
- 除非用户明确要求，否则不要提交、推送、发布或创建远程仓库。
