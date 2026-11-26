# 香港分发源与多服务器同步

## 来源层级

项目采用三个层级：

1. 本地 Git 仓库保存脚本、示例和文档，是代码权威来源；
2. SSH 别名 `hongkong` 保存已校验脚本和 Cloudflare 主凭据；
3. 其他服务器从香港复制脚本与凭据，并保留自身运行配置。

Cloudflare 凭据的维护主副本固定为 `hongkong:/root/.config/wifi-fail2ban/cloudflare.credentials`。以这个服务器文件为准，不要求在密码管理器另存一份；其他节点的副本用于运行，root 受限备份用于恢复。

当前脚本只为已启用的 `vaultwarden` jail 配置 Cloudflare 联动；SSH、FTP 和 `recidive` 使用本机 UFW。向新服务器分发 Token 不会自动把所有 jail 的封禁同步到 Cloudflare，仍须核对该服务器启用的应用与动作。

本文说明通用分发与切换流程。保存路径和兼容代码已确定，不代表真实 Token 已创建或认证已切换；实际模式须通过服务器上的辅助程序和部署验证确认。

香港服务器上的路径：

```text
/root/wifi-fail2ban-distribution/scripts/wifi_fail2ban.sh
/root/wifi-fail2ban-distribution/scripts/audit_fail2ban.sh
/root/wifi-fail2ban-distribution/scripts/wifi_cloudflare.py
/root/wifi-fail2ban-distribution/config/wifi-cloudflare.conf
/root/wifi-fail2ban-distribution/SHA256SUMS
/root/.config/wifi-fail2ban/cloudflare.credentials
/root/.config/wifi-fail2ban/deployment.env
```

分发目录和凭据目录均为 `root:root`、`700`。脚本和 Python 辅助程序权限为 `700`，动作模板为 `644`，凭据与校验文件权限为 `600`。

## 更新香港脚本

先在本地仓库完成检查：

```bash
bash -n scripts/wifi_fail2ban.sh
bash -n scripts/audit_fail2ban.sh
python3 -B tests/test_configuration.py
python3 -B tests/test_cloudflare.py
```

随后上传到临时路径并由 root 安装：

```bash
scp scripts/wifi_fail2ban.sh scripts/audit_fail2ban.sh \
  scripts/wifi_cloudflare.py config/wifi-cloudflare.conf hongkong:/tmp/
ssh hongkong 'install -o root -g root -m 700 \
  /tmp/wifi_fail2ban.sh \
  /root/wifi-fail2ban-distribution/scripts/wifi_fail2ban.sh'
ssh hongkong 'install -o root -g root -m 700 \
  /tmp/audit_fail2ban.sh \
  /root/wifi-fail2ban-distribution/scripts/audit_fail2ban.sh'
ssh hongkong 'install -d -o root -g root -m 700 \
  /root/wifi-fail2ban-distribution/config; \
  install -o root -g root -m 700 /tmp/wifi_cloudflare.py \
    /root/wifi-fail2ban-distribution/scripts/wifi_cloudflare.py; \
  install -o root -g root -m 644 /tmp/wifi-cloudflare.conf \
    /root/wifi-fail2ban-distribution/config/wifi-cloudflare.conf'
ssh hongkong 'cd /root/wifi-fail2ban-distribution && \
  sha256sum scripts/wifi_fail2ban.sh scripts/audit_fail2ban.sh \
    scripts/wifi_cloudflare.py config/wifi-cloudflare.conf > SHA256SUMS && \
  chmod 600 SHA256SUMS && sha256sum -c SHA256SUMS'
```

更新分发副本本身不会修改香港的 Fail2Ban 配置。只有明确执行部署脚本时才会应用规则。

## 更新主凭据

Token 模式的主副本包含 `CF_API_TOKEN` 和 `CF_ACCOUNT_ID`，必须是属主 `root:root`、权限 `600` 的普通文件；父目录 `/root/.config/wifi-fail2ban` 为 `root:root`、`700`。真实值只在香港服务器上维护，不输出到聊天、终端日志或 Git。

创建或轮换时，先准备同目录候选文件 `cloudflare.credentials.new`，不直接编辑正在使用的主副本。以下在香港服务器上执行；候选文件若已存在，先确认它是否属于尚未完成的切换：

```bash
ssh hongkong
sudo install -d -o root -g root -m 700 \
  /root/.config/wifi-fail2ban /root/fail2ban-backups
sudoedit /root/.config/wifi-fail2ban/cloudflare.credentials.new
sudo chown root:root /root/.config/wifi-fail2ban/cloudflare.credentials.new
sudo chmod 600 /root/.config/wifi-fail2ban/cloudflare.credentials.new
sudo /usr/bin/python3 /usr/local/libexec/wifi-fail2ban/wifi_cloudflare.py \
  check --credentials /root/.config/wifi-fail2ban/cloudflare.credentials.new
```

`check` 只 GET 指定账号的规则列表，不证明写权限。核对旧规则的归属和处理方式，在临时 Fail2Ban 配置中验证新动作及本节点设置；通过后再备份和原子切换。下面的命令由香港服务器 root 在这些验证完成后执行：

```bash
(
set -eu
umask 077
credential_backup_dir="$(mktemp -d /root/fail2ban-backups/cloudflare-rotation.XXXXXX)"
if test -f /root/.config/wifi-fail2ban/cloudflare.credentials; then
  install -o root -g root -m 600 \
    /root/.config/wifi-fail2ban/cloudflare.credentials \
    "${credential_backup_dir}/cloudflare.credentials"
fi
mv -f -- /root/.config/wifi-fail2ban/cloudflare.credentials.new \
  /root/.config/wifi-fail2ban/cloudflare.credentials
)
```

候选文件与正式文件位于同一目录，通过重命名原子替换，避免读到写入一半的凭据。备份目录为 root 专用 `700`，备份文件为 `600`；保留对应部署配置以供回退，不将备份上传到仓库或本机文档。

随后应用已校验的部署脚本并验证运行模式，再按下一节同步到全部使用方，完成相关节点的动作、实际读写和回退验证。`deployment.env` 是服务器专用设置，香港副本只代表香港自身，不能随主凭据覆盖其他节点。

## 同步到目标服务器

以下命令在可信管理电脑上执行，`<target>` 替换为目标 SSH 别名。`scp -3` 通过管理电脑转发两个远端之间的数据，但不把凭据保存为本地文件。

先准备目标服务器 root 专用目录，并为现有凭据和运行设置创建独立备份：

```bash
ssh <target> 'set -eu; install -d -o root -g root -m 700 \
  /root/.config/wifi-fail2ban /root/fail2ban-backups; \
  umask 077; \
  credential_backup_dir=$(mktemp -d /root/fail2ban-backups/cloudflare-sync.XXXXXX); \
  if test -f /root/.config/wifi-fail2ban/cloudflare.credentials; then \
    install -o root -g root -m 600 /root/.config/wifi-fail2ban/cloudflare.credentials \
      "$credential_backup_dir/cloudflare.credentials"; \
  fi; \
  if test -f /root/.config/wifi-fail2ban/deployment.env; then \
    install -o root -g root -m 600 /root/.config/wifi-fail2ban/deployment.env \
      "$credential_backup_dir/deployment.env"; \
  fi'
```

通过 SSH 安全复制主凭据到目标的 root 专用候选文件；非敏感脚本使用临时安装路径：

```bash
scp -3 hongkong:/root/.config/wifi-fail2ban/cloudflare.credentials \
  <target>:/root/.config/wifi-fail2ban/cloudflare.credentials.new
scp -3 hongkong:/root/wifi-fail2ban-distribution/scripts/wifi_fail2ban.sh \
  <target>:/tmp/wifi_fail2ban.sh.new
scp -3 hongkong:/root/wifi-fail2ban-distribution/scripts/audit_fail2ban.sh \
  <target>:/tmp/audit_fail2ban.sh.new
scp -3 hongkong:/root/wifi-fail2ban-distribution/scripts/wifi_cloudflare.py \
  <target>:/tmp/wifi_cloudflare.py.new
scp -3 hongkong:/root/wifi-fail2ban-distribution/config/wifi-cloudflare.conf \
  <target>:/tmp/wifi-cloudflare.conf.new
```

先由目标服务器 root 安装脚本支持包并限制候选文件权限，此时不替换正在使用的凭据：

```bash
ssh <target> 'set -eu; chown root:root /root/.config/wifi-fail2ban/cloudflare.credentials.new; \
  chmod 600 /root/.config/wifi-fail2ban/cloudflare.credentials.new; \
  install -o root -g root -m 700 \
  /tmp/wifi_fail2ban.sh.new /home/Wi-Fi/wifi_fail2ban.sh; \
  install -o root -g root -m 700 \
  /tmp/audit_fail2ban.sh.new /root/audit_fail2ban.sh; \
  install -o root -g root -m 700 \
  /tmp/wifi_cloudflare.py.new /home/Wi-Fi/wifi_cloudflare.py; \
  install -o root -g root -m 644 \
  /tmp/wifi-cloudflare.conf.new /home/Wi-Fi/wifi-cloudflare.conf; \
  rm -f /tmp/wifi_fail2ban.sh.new /tmp/audit_fail2ban.sh.new \
    /tmp/wifi_cloudflare.py.new /tmp/wifi-cloudflare.conf.new'
```

不从香港复制或覆盖目标的 `deployment.env`。新服务器以仓库示例创建自己的 root 专用副本，填写自身 `MANUAL_IPS`、日志路径和功能开关；不要把真实值带回仓库。迁移旧版本时确认 `ENABLE_FRPS=0` 已持久保存。每个节点必须设置稳定、唯一的 `CF_RULE_OWNER`，不能复制香港节点的标记。

随后在目标服务器对候选文件执行同样的 `check`，验证临时 Fail2Ban 配置与本节点设置。新服务器尚未安装辅助程序时，可用已校验、root 管理的 `/home/Wi-Fi/wifi_cloudflare.py` 检查候选文件。全部通过后，由 root 在同目录将 `.new` 原子重命名为 `cloudflare.credentials`，再应用部署脚本；不要直接用复制命令覆盖活动凭据。

复制完成不等于应用。先确认目标服务器已通过宝塔安装 Fail2Ban、UFW 正常，并复核其 `deployment.env`，再运行部署脚本。应用后逐项读取所有运行 jail 的 `ignoreip`，确认后备管理来源存在。

## 安全边界

香港是凭据的维护主副本，但所有直接调用 Cloudflare 的目标服务器仍需要保存本地副本。因此任何一台目标服务器被入侵，都可能泄露当前 Key 或 Token；账号权限范围不能替代服务器本身的保护。

同一个指定账号的 Token 可以供多个节点使用。轮换时先更新香港主副本，再同步并验证全部使用该 Token 的节点，完成后才考虑撤销旧 Token。节点的唯一来源标记用于区分规则归属，不能解决多个节点对同一账号、同一 IP 的共享封禁协调；需要共同维护同一 IP 时，须另外设计协调机制。

如果要求 Key 只存在香港，需要另行设计认证后的封禁中继服务，让其他服务器只发送封禁请求，而不接触 Cloudflare凭据。这不属于当前复制式方案。
