# 规则说明

## SSH 与 FTP

这两项由宝塔创建和展示，本项目只覆盖邮件动作。

| jail | 端口 | `findtime` | `maxretry` | `bantime` | 动作 |
| --- | ---: | ---: | ---: | ---: | --- |
| `sshd` | 22 | 300 秒 | 5 | 86400 秒 | UFW |
| `ftpd` | 21 | 300 秒 | 5 | 86400 秒 | UFW |

宝塔以后修改端口、时间或开关时，本项目不会覆盖这些参数。

## 重复攻击者

`recidive` 读取 Fail2Ban 自身日志，识别在多个 jail 中反复被封禁的地址。

| 参数 | 值 |
| --- | --- |
| `findtime` | 86400 秒 |
| `maxretry` | 2 |
| 初始 `bantime` | 1209600 秒（14 天） |
| 递增倍率 | 2 |
| 最长封禁 | 2592000 秒（30 天） |
| 动作 | UFW，全端口 |

## FRP

`frps` 读取 `/home/Wi-Fi/frps/logs/frps.log`，匹配下列客户端出现的用户连接：

```regex
^.*\[(Openwrt-ssh|Pve-ssh|WiFi-Windows)\] get a user connection \[<HOST>:[0-9]+\]
```

在 600 秒内出现 3 次后封禁 86400 秒，重复触发按 2 倍递增，最长 30 天。动作是 UFW 全端口封禁。

此规则针对指定代理客户端的外部连接来源，不用于统计普通 FRP 控制连接。新增客户端名称时，需要同时更新正则、测试日志和本页。

当脚本未检测到 FRP 服务或日志时，会在高优先级配置中显式写入 `enabled = false`，防止旧的 `jail.local` 继续启用失效规则。

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

自定义 jail 始终忽略 `127.0.0.1/8` 和 `::1`。其他管理地址通过 `MANUAL_IPS` 在运行时传入，不写入仓库。
