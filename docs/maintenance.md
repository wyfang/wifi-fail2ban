# 部署、更新和恢复

## 首次部署

先在宝塔面板完成 Fail2Ban 安装，并确认 UFW 处于启用状态。脚本还需要 `curl`、`logrotate` 和 `systemd-tmpfiles`。

将 Cloudflare 凭据放到服务器 root 专用目录：

```bash
sudo install -d -o root -g root -m 700 /root/.config/wifi-fail2ban
sudo install -o root -g root -m 600 \
  config/cloudflare.credentials.example \
  /root/.config/wifi-fail2ban/cloudflare.credentials
```

随后只在服务器上编辑真实值，不要把文件复制回仓库。

安装服务器专用运行设置：

```bash
sudo install -o root -g root -m 600 \
  config/deployment.env.example \
  /root/.config/wifi-fail2ban/deployment.env
sudoedit /root/.config/wifi-fail2ban/deployment.env
```

设置文件使用纯 `KEY=value` 格式，不需要也不允许依赖 shell 执行。脚本会安全解析它，运行时环境变量仍可临时覆盖文件值。

安装脚本并运行：

```bash
sudo install -o root -g root -m 700 \
  scripts/wifi_fail2ban.sh /home/Wi-Fi/wifi_fail2ban.sh
sudo /home/Wi-Fi/wifi_fail2ban.sh
```

## 更新

更新前先保存 `/etc/fail2ban`、`/var/lib/fail2ban`、部署脚本和 root 凭据文件。不要在备份中打印或复制凭据到聊天、日志或 Git。

多服务器环境先更新本地 Git 仓库，再按[香港分发流程](./distribution.md)更新香港副本和其他服务器。不要直接在各生产服务器上形成不同的脚本版本。

脚本会先复制 `/etc/fail2ban` 到临时目录并执行配置测试。测试通过后才更新正式文件；内容没有变化时不会重载服务。

如果系统软件包已经提供 `/etc/logrotate.d/fail2ban`，脚本会复用它；只有宝塔安装缺少该文件时才创建 `/etc/logrotate.d/wifi-fail2ban`。

配置发生变化时，脚本使用 Fail2Ban 自身的 `reload --restart --all` 重建 jail，但不终止服务进程，也不会传入 `--unban` 或删除数据库。每次执行都会调用 `flushlogs`，确保日志轮转或异常删除后重新打开正确文件。

更新后运行：

```bash
sudo fail2ban-client -t
sudo fail2ban-client status
sudo scripts/audit_fail2ban.sh
```

生产服务器通常没有仓库路径，可以把审计脚本安装到 root 专用位置后执行。

## 重复执行检查

记录运行前后的 Fail2Ban 主进程：

```bash
systemctl show fail2ban -p MainPID -p ActiveEnterTimestampMonotonic
sudo /home/Wi-Fi/wifi_fail2ban.sh
systemctl show fail2ban -p MainPID -p ActiveEnterTimestampMonotonic
```

当配置没有变化时，进程号和启动时间应保持一致，输出应包含 `service reload is not required`。

## 恢复

恢复配置时优先恢复文本配置和凭据，不要跨服务器覆盖运行数据库。恢复后必须先测试：

```bash
sudo fail2ban-client -t
sudo systemctl reload fail2ban
sudo fail2ban-client status
```

如果测试失败，不要重启服务。保留当前运行实例，修正配置后再次测试。

## 停用自定义功能

可以通过环境变量逐项关闭：

```bash
sudo ENABLE_FRPS=0 ENABLE_VAULTWARDEN=0 \
  /home/Wi-Fi/wifi_fail2ban.sh
```

`recidive` 和 SSH/FTP 的无邮件覆盖属于当前固定基线；如需改变，应先更新脚本、规则文档和变更记录。
