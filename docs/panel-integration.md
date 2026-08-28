# 宝塔集成与加载顺序

## 文件归属

宝塔插件拥有：

- `/www/server/panel/plugin/fail2ban/`
- `/www/server/panel/data/fail2ban.pl`
- `/etc/fail2ban/jail.local`
- Fail2Ban 的安装、卸载、服务启停和面板内基础参数

本项目拥有：

- `/etc/fail2ban/jail.d/90-wifi.local`
- `/etc/fail2ban/filter.d/wifi-frps.conf`
- `/etc/fail2ban/filter.d/wifi-vaultwarden.conf`
- `/etc/logrotate.d/wifi-fail2ban`
- `/etc/logrotate.d/wifi-services`
- `/etc/tmpfiles.d/wifi-fail2ban.conf`
- `/home/Wi-Fi/wifi_fail2ban.sh`

不要把宝塔的 `jail.local` 复制进仓库，也不要让部署脚本覆盖它。

## `90-` 的含义

Fail2Ban 先读取主配置，再按名称顺序读取局部配置。`.local` 文件用于覆盖默认值，`90-wifi.local` 表示这是较晚加载的项目级覆盖。

`90-` 不是端口、版本或封禁优先级。它为 `99-` 之类的临时紧急覆盖保留空间，同时让维护者一眼看出文件顺序。

## 面板显示范围

宝塔面板通常只完整展示它写入 `jail.local` 的 jail。`recidive`、`frps` 和 `vaultwarden` 即使运行正常，也可能不会出现在全部面板页面中。

判断真实运行状态应以以下命令为准：

```bash
sudo fail2ban-client -t
sudo fail2ban-client status
sudo fail2ban-client status vaultwarden
```

## 重新安装宝塔插件

重新安装可能重建 `/etc/fail2ban`。正确顺序是：

1. 备份配置、脚本、凭据与状态；
2. 通过宝塔卸载和安装插件；
3. 确认宝塔基础 jail 正常；
4. 重新运行本项目脚本；
5. 验证五个 jail 和重复执行结果。

不要把旧服务器的 SQLite 封禁数据库直接覆盖到新安装中。
