# Wi-Fi Fail2Ban

维护宝塔服务器上的 Fail2Ban 基础防护与 FRP、Vaultwarden、Cloudflare 扩展规则。

[维护文档](./docs/maintenance.md) · [English](./README.en.md)

## 功能

- 保留宝塔对 SSH、FTP 和 `/etc/fail2ban/jail.local` 的管理。
- 使用独立配置维护重复攻击者、FRP 和 Vaultwarden 防护。
- 为 Vaultwarden 同时执行本机 UFW 与 Cloudflare 封禁。
- 提供可重复执行的部署脚本，不重复叠加规则，不清空封禁数据库。
- 提供只读审计脚本和维护、恢复、安全说明。

## 使用

适用于使用 systemd、UFW 和宝塔 Fail2Ban 插件的 Debian/Ubuntu 服务器。部署前应先在宝塔面板安装并启动 Fail2Ban。

```bash
sudo install -D -o root -g root -m 700 \
  scripts/wifi_fail2ban.sh /home/Wi-Fi/wifi_fail2ban.sh
sudo /home/Wi-Fi/wifi_fail2ban.sh
```

服务器专用白名单通过 `MANUAL_IPS` 传入，Cloudflare 凭据使用 root 专用文件。不要把真实值提交到仓库，具体格式见 [安全与凭据](./docs/security.md)。

## 说明

### 管理边界

宝塔继续拥有 `/etc/fail2ban/jail.local`。本项目生成 `/etc/fail2ban/jail.d/90-wifi.local` 及带 `wifi-` 前缀的文件；宝塔面板可能只显示它支持的基础 jail。

脚本会读取本地安全日志，并在 Vaultwarden 触发封禁时调用 Cloudflare API。它不会上传日志、保存封禁数据库副本或修改应用日志属主。配置先在临时副本中通过 `fail2ban-client -t` 后才写入正式目录；配置变化时会重载 Fail2Ban，无变化时不操作服务。

### 相关文档

- [当前基线](./docs/current-baseline.md)
- [规则说明](./docs/rules.md)
- [宝塔集成与加载顺序](./docs/panel-integration.md)
- [香港分发源与多服务器同步](./docs/distribution.md)
- [部署、更新和恢复](./docs/maintenance.md)
- [安全与凭据](./docs/security.md)

## 版权说明

本项目当前未设置开源许可证，除非另有书面说明，保留所有权利。Fail2Ban、UFW、Cloudflare 及其他第三方软件和服务遵循各自条款，详见 [权利范围](./LICENSE_SCOPE.md)。
