# 规则说明

## SSH 与 FTP

这两项由宝塔创建和展示。本项目覆盖邮件动作，并通过 `%(known/ignoreip)s` 继承宝塔已有白名单、追加 `::1` 与 `MANUAL_IPS`，不重写宝塔的 `jail.local`。

| jail | 端口 | `findtime` | `maxretry` | `bantime` | 动作 |
| --- | ---: | ---: | ---: | ---: | --- |
| `sshd` | 22 | 300 秒 | 5 | 86400 秒 | UFW |
| `ftpd` | 21 | 300 秒 | 5 | 86400 秒 | UFW |

宝塔以后修改端口、时间或开关时，本项目不会覆盖这些参数。

## 重复攻击者

`recidive` 读取 Fail2Ban 自身日志，累计地址被封禁的次数；不要求每次封禁来自不同 jail。

| 参数 | 值 |
| --- | --- |
| `findtime` | 86400 秒 |
| `maxretry` | 2 |
| 初始 `bantime` | 1209600 秒（14 天） |
| 递增倍率 | 2 |
| 最长封禁 | 2592000 秒（30 天） |
| 动作 | UFW，全端口 |

## FRP

**默认关闭 `frps` jail。** `get a user connection` 只表示外部连接到达 FRP，成功的 SSH、RDP 会话及普通连接探测都会计数。FRPS 转发加密流量，不能从这条日志判断后端 SSH/RDP 的认证结果；真实认证失败应由后端服务日志判定。

脚本在 `90-wifi.local` 显式写入 `enabled = false`，覆盖旧 `jail.local` 中的启用值。未设置 `ENABLE_FRPS`、设置为 `0` 或旧值 `auto` 时都保持关闭；`auto` 会输出迁移提示。关闭 jail 后，已存在的 FRP 日志仍按原策略轮转。

只有明确需要按连接次数限制来源时，才在服务器 `deployment.env` 设置 `ENABLE_FRPS=1` 并核对 `MANUAL_IPS`。该模式要求日志存在且可读，并警告正常连接也计数。它读取 `/home/Wi-Fi/frps/logs/frps.log`，匹配以下连接记录：

```regex
^.*\[(Openwrt-ssh|Pve-ssh|WiFi-Windows)\] get a user connection \[<HOST>:[0-9]+\]
```

显式启用后的兼容默认值为 `FRPS_FINDTIME=600`、`FRPS_MAXRETRY=3`、`FRPS_BANTIME=86400`，可在部署参数中修改为正整数；时间单位为秒。达到次数后按 UFW **全端口**封禁，重复触发按 2 倍递增，最长 30 天，还可能被 `recidive` 延长封禁。这个模式不能标为认证失败防护。

此规则针对指定代理客户端的外部连接来源，不用于统计普通 FRP 控制连接。新增客户端名称时，需要同时更新正则、测试日志和本页。

部署前须检查服务器是否仍有旧的 `ENABLE_FRPS=1`；该值会继续显式启用连接计数，应持久改为 `0` 才能迁移到默认策略。停止 `frps` jail 会由其动作清理当前由它维护的封禁，因此先记录其封禁名单；这不等于清空 Fail2Ban 数据库，也不自动解封其他 jail 中的既有封禁。误封恢复须核实具体地址在 `recidive` 等 jail 及 UFW 中的状态。

## Vaultwarden

`vaultwarden` 读取 `/home/Wi-Fi/Bitwarden/data/log/vaultwarden.log`，识别：

- 无效管理令牌；
- 无效 TOTP；
- 用户名或密码错误；
- Vaultwarden 兼容版本输出的失败登录格式。

`/api/alive` 健康检查被忽略。在 600 秒内出现 3 次后封禁 86400 秒，重复触发按 2 倍递增，最长 30 天。

每次封禁同时执行：

1. UFW 本机全端口封禁；
2. Cloudflare IP Access Rule 封禁。

Cloudflare动作使用 `Fail2Ban <jail>` 备注寻找对应规则，解封时不会按 IP 盲目删除其他手工规则。

当脚本未检测到 Vaultwarden 安装时，会显式关闭该 jail，并且不会加载 Cloudflare动作。

## 白名单

自定义 jail 始终忽略 `127.0.0.1/8` 和 `::1`。其他管理地址通过 `MANUAL_IPS` 在运行时传入，不写入仓库；同一参数也追加到 SSH、FTP 的既有白名单。部署后应逐项读取所有运行 jail 的 `ignoreip`，确认继承与追加结果，而不是仅查看生成文件。
