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

## SSH 与 FRP 防误封

- 旧 `frps` jail 匹配 `Openwrt-ssh`、`Pve-ssh`、`WiFi-Windows` 的
  `get a user connection` 日志；正常 SSH/RDP、成功登录和连接探测均计数，
  不能当作后端认证失败。兼容默认阈值为同一 IP 10 分钟内 3 次连接，由 UFW
  全端口封禁 24 小时；重复触发最长 30 天，还可能叠加 `recidive` 封禁。
- 管理入口维护时保持 `ENABLE_FRPS=0`，并检查服务器 `deployment.env` 中的持久值。
  当前脚本未设置该值或使用旧 `auto` 时均关闭；旧配置残留的 `1` 会继续启用。
  不得为了加强 SSH 防护重新开启连接计数规则；确需连接限流时必须另有用户明确要求，
  并说明成功连接也会计数及全端口封禁影响。
- 经 FRP 批量或反复连接前，优先从已授权的现有会话或备用入口读取 FRPS 所在
  服务器的 `fail2ban-client status`，核实 `frps` 是否仍在运行；同时检查
  `recidive` 及其他运行 jail 的 `ignoreip`。配置文件中的 `enabled = false`
  不能代替运行状态核验。
- 白名单以服务器 `MANUAL_IPS` 与各运行 jail 的实际值为准；先确认服务器看到的
  当前管理来源，不假定本机出口始终不变。真实 IP 与凭据不得写入仓库；白名单只表示
  不被对应 jail 自动封禁，不是入口访问控制，也不自动解除已有封禁。
- 初次 SSH 使用 `BatchMode=yes`、`IdentitiesOnly=yes`、`ConnectionAttempts=1`
  和合理的 `ConnectTimeout`，只尝试一次；连接成功后优先复用会话、批量执行命令，
  不用反复登录或 TCP 探测作为健康检查。不在同一入口并发重复建立 SSH 连接。
- 认证前断开、异常超时或疑似误封时停止快速重试，从已授权备用入口核实该来源在
  `frps`、`recidive`、其他相关 jail 及 UFW 中的封禁，只解封确认属于管理访问的
  地址。不清空 Fail2Ban 数据库、不全量解封、不停止整套服务；没有可用入口时说明
  阻碍，不能循环重试直至触发或加重封禁。
- 已授权任务中的只读检查和 SSH 会话复用无需再次征求许可；上述检查不扩大变更权限。

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
