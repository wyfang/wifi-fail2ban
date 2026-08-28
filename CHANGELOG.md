# 变更记录

## 2026-08-26

- 建立宝塔兼容的 Fail2Ban 维护项目。
- 记录 SSH、FTP、recidive、FRP 和 Vaultwarden 五项 jail 基线。
- 将自定义规则放入 `/etc/fail2ban/jail.d/90-wifi.local`。
- 增加 FRP 与 Vaultwarden 过滤器、Fail2Ban 与应用日志轮转规则。
- 将 Cloudflare 凭据从脚本迁移到 root 专用文件。
- 移除 SSH 与 FTP 的邮件通知动作，只保留防火墙封禁。
- 验证部署脚本重复运行时不重载服务、不追加规则、不清空数据库。
- 建立香港服务器分发源，集中保存已校验脚本和 Cloudflare 主凭据。
- 在服务不存在时显式关闭遗留的 FRP 与 Vaultwarden jail，避免旧配置重新启用无效日志路径。
- 增加 root 专用 `deployment.env`，让统一脚本安全读取每台服务器的白名单、日志路径和功能开关。
- 发行版已提供 Fail2Ban 日志轮转时自动复用，避免与 `wifi-fail2ban` 产生重复日志条目。
- 配置变化时完整重建受影响 jail，并刷新 Fail2Ban 日志句柄，兼容旧版热重载未重新挂载动作的问题。
- 清理香港的系统包与宝塔 Python 双重安装，通过宝塔官方接口重装插件 `2.6` 并恢复正式基线。
