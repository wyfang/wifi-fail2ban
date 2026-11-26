# 部署、更新和恢复

## 首次部署

先在宝塔面板完成 Fail2Ban 安装，并确认 UFW 处于启用状态。脚本还需要 `curl`、`logrotate` 和 `systemd-tmpfiles`。

凭据主副本固定保存在 `hongkong:/root/.config/wifi-fail2ban/cloudflare.credentials`。新服务器通过 [香港分发流程](./distribution.md) 安全取得运行副本，不自行维护另一个主副本。首次在香港准备凭据时，以 root 专用候选文件开始：

```bash
sudo install -d -o root -g root -m 700 /root/.config/wifi-fail2ban
sudo install -o root -g root -m 600 \
  config/cloudflare.credentials.example \
   /root/.config/wifi-fail2ban/cloudflare.credentials.new
```

随后只在香港候选文件中编辑真实值，验证并创建 root 受限备份后原子切换为正式文件；不要把文件复制回仓库。上述初始化步骤和下述操作均为通用流程，不代表 Token 已创建或认证切换已经完成。

安装服务器专用运行设置：

```bash
sudo install -o root -g root -m 600 \
  config/deployment.env.example \
  /root/.config/wifi-fail2ban/deployment.env
sudoedit /root/.config/wifi-fail2ban/deployment.env
```

设置文件使用纯 `KEY=value` 格式，不需要也不允许依赖 shell 执行。脚本会安全解析它，运行时环境变量仍可临时覆盖文件值。

安装脚本与 Cloudflare 支持文件后运行：

```bash
sudo install -o root -g root -m 700 \
  scripts/wifi_fail2ban.sh /home/Wi-Fi/wifi_fail2ban.sh
sudo install -o root -g root -m 700 \
  scripts/wifi_cloudflare.py /home/Wi-Fi/wifi_cloudflare.py
sudo install -o root -g root -m 644 \
  config/wifi-cloudflare.conf /home/Wi-Fi/wifi-cloudflare.conf
sudo /home/Wi-Fi/wifi_fail2ban.sh
```

## 更新

更新前先保存 `/etc/fail2ban`、`/var/lib/fail2ban`、部署脚本和 root 凭据文件。不要在备份中打印或复制凭据到聊天、日志或 Git。

多服务器环境先更新本地 Git 仓库，再按[香港分发流程](./distribution.md)更新香港副本和其他服务器。不要直接在各生产服务器上形成不同的脚本版本。

脚本会先复制 `/etc/fail2ban` 到临时目录并执行配置测试。测试通过后才更新正式文件；内容没有变化时不会重载服务。

升级到默认关闭 FRP 连接计数的版本时，先检查目标服务器 `deployment.env` 并将 `ENABLE_FRPS` 持久设为 `0`。旧 `auto` 会兼容关闭，旧 `1` 仍会显式启用；只在某次命令中传入 `ENABLE_FRPS=0` 不能替代持久配置。保持各服务器原有 `MANUAL_IPS`，并在部署后逐项检查 SSH、FTP、recidive 和其他运行 jail 的 `ignoreip`。

关闭 `frps` 时，其动作会清理该 jail 当前维护的封禁；部署前先保存其封禁名单和对应日志。此操作不会删除 Fail2Ban 历史数据库，也不会全量解封其他 jail。若已有误封，先通过备用管理通道确认真实来源 IP，再检查该地址在 `recidive`、其他 jail 与 UFW 的状态，仅处理已核实的误封地址；不要清空数据库或停掉整套防护。

如果系统软件包已经提供 `/etc/logrotate.d/fail2ban`，脚本会复用它；只有宝塔安装缺少该文件时才创建 `/etc/logrotate.d/wifi-fail2ban`。

配置发生变化时，脚本使用 Fail2Ban 自身的 `reload --restart --all` 重建 jail，但不终止服务进程，也不会传入 `--unban` 或删除数据库。每次执行都会调用 `flushlogs`，确保日志轮转或异常删除后重新打开正确文件。

更新后运行：

```bash
sudo fail2ban-client -t
sudo fail2ban-client status
sudo scripts/audit_fail2ban.sh
```

生产服务器通常没有仓库路径，可以把审计脚本安装到 root 专用位置后执行。

## API Token 兼容与切换

发布兼容代码时同时分发 `wifi_fail2ban.sh`、`audit_fail2ban.sh`、`wifi_cloudflare.py` 和 `wifi-cloudflare.conf`。部署脚本先测试完整 Fail2Ban 配置，再将辅助程序安装到 `/usr/local/libexec/wifi-fail2ban/wifi_cloudflare.py`、动作安装到 `/etc/fail2ban/action.d/wifi-cloudflare.conf`。已有 `CF_EMAIL`/`CF_KEY` 仍选用原生 `cloudflare` 动作，不会因为安装支持文件就切换认证。

旧的单文件部署在使用 Global API Key 时仍可运行；启用 Token 必须具备完整的辅助程序与动作文件。更新时应同步完整支持包，避免仅更新主脚本后继续复用旧辅助程序。

切换前由维护者在香港的 `cloudflare.credentials.new` 安全填写 `CF_API_TOKEN` 和 `CF_ACCOUNT_ID`，并在各服务器自身 `deployment.env` 设置稳定、唯一的 `CF_RULE_OWNER`。主副本与分发副本均通过候选验证、root 受限备份和同目录原子重命名切换；不复制节点的 `deployment.env`。凭据格式、账号权限、旧规则归属和撤销边界见 [安全与凭据](./security.md)。即使旧 Key 字段仍在文件中，Token 字段出现后也优先选择 Token；无效、缺项或空 Token 不会静默回退。回退到旧模式应从受限备份准备候选文件，验证后原子恢复，再重新应用。

默认先 GET 指定账号的 IP Access Rules；读取失败时，在安装托管配置之前退出。读取检查不证明写权限；需要以后另行验证真实封禁、解封及回退，不能把兼容代码部署当成令牌切换完成。部署时不要设置 `VERIFY_CLOUDFLARE=0` 跳过首次令牌检查。

可独立执行不含秘密的只读检查：

```bash
sudo /usr/bin/python3 /usr/local/libexec/wifi-fail2ban/wifi_cloudflare.py \
  check --credentials /root/.config/wifi-fail2ban/cloudflare.credentials.new
sudo AUDIT_CLOUDFLARE_CHECK=1 /root/audit_fail2ban.sh
```

审计默认只读取凭据类型与文件权限，不发起账号 API 请求；`AUDIT_CLOUDFLARE_CHECK=1` 才对 Token 模式额外 GET。自定义凭据路径时，通过审计脚本的 `CREDENTIAL_FILE` 环境变量传入同一路径。不要把 Token 放进命令参数，也不要输出原生动作的完整配置转储，其中可能仍有旧 Key。

上例的 `check` 验证候选文件，审计检查已部署的活动凭据；它们不是同一步。多个节点可共用指定账号的 Token，但轮换必须同步并验证所有使用节点，节点来源标记本身不负责协调对同一 IP 的共享封禁。

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

FRP 连接计数默认关闭。可以通过环境变量在单次运行中逐项关闭：

```bash
sudo ENABLE_FRPS=0 ENABLE_VAULTWARDEN=0 \
  /home/Wi-Fi/wifi_fail2ban.sh
```

`recidive` 和 SSH/FTP 的无邮件覆盖属于当前固定基线；如需改变，应先更新脚本、规则文档和变更记录。

需要长期停用时，应将对应的 `ENABLE_*` 值写入服务器 root 专用的 `deployment.env`，并检查香港分发设置没有把旧值带回。保留 `ENABLE_VAULTWARDEN=auto` 可继续按原规则保护已安装的 Vaultwarden。
