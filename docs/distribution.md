# 香港分发源与多服务器同步

## 来源层级

项目采用三个层级：

1. 本地 Git 仓库保存脚本、示例和文档，是代码权威来源；
2. SSH 别名 `hongkong` 保存已校验脚本和 Cloudflare 主凭据；
3. 其他服务器从香港复制脚本与凭据，并保留自身运行配置。

香港服务器上的路径：

```text
/root/wifi-fail2ban-distribution/scripts/wifi_fail2ban.sh
/root/wifi-fail2ban-distribution/scripts/audit_fail2ban.sh
/root/wifi-fail2ban-distribution/SHA256SUMS
/root/.config/wifi-fail2ban/cloudflare.credentials
/root/.config/wifi-fail2ban/deployment.env
```

两个目录均为 `root:root`、`700`。脚本权限为 `700`，凭据与校验文件权限为 `600`。

## 更新香港脚本

先在本地仓库完成检查：

```bash
bash -n scripts/wifi_fail2ban.sh
bash -n scripts/audit_fail2ban.sh
```

随后上传到临时路径并由 root 安装：

```bash
scp scripts/wifi_fail2ban.sh scripts/audit_fail2ban.sh hongkong:/tmp/
ssh hongkong 'install -o root -g root -m 700 \
  /tmp/wifi_fail2ban.sh \
  /root/wifi-fail2ban-distribution/scripts/wifi_fail2ban.sh'
ssh hongkong 'install -o root -g root -m 700 \
  /tmp/audit_fail2ban.sh \
  /root/wifi-fail2ban-distribution/scripts/audit_fail2ban.sh'
ssh hongkong 'cd /root/wifi-fail2ban-distribution && \
  sha256sum scripts/wifi_fail2ban.sh scripts/audit_fail2ban.sh > SHA256SUMS && \
  chmod 600 SHA256SUMS && sha256sum -c SHA256SUMS'
```

更新分发副本本身不会修改香港的 Fail2Ban 配置。只有明确执行部署脚本时才会应用规则。

## 更新主凭据

真实凭据和共享运行设置只在香港服务器上编辑：

```bash
ssh hongkong
sudoedit /root/.config/wifi-fail2ban/cloudflare.credentials
sudo chown root:root /root/.config/wifi-fail2ban/cloudflare.credentials
sudo chmod 600 /root/.config/wifi-fail2ban/cloudflare.credentials
sudoedit /root/.config/wifi-fail2ban/deployment.env
sudo chown root:root /root/.config/wifi-fail2ban/deployment.env
sudo chmod 600 /root/.config/wifi-fail2ban/deployment.env
```

更新后应执行只读 Cloudflare认证检查，再同步到其他服务器。不要通过终端输出、Git diff 或聊天查看真实值。

## 同步到目标服务器

以下命令在可信管理电脑上执行，`<target>` 替换为目标 SSH 别名。`scp -3` 通过管理电脑转发两个远端之间的数据，但不把凭据保存为本地文件。

先准备目录并备份目标服务器现有凭据：

```bash
ssh <target> 'install -d -o root -g root -m 700 \
  /root/.config/wifi-fail2ban /root/fail2ban-backups; \
  if test -f /root/.config/wifi-fail2ban/cloudflare.credentials; then \
    cp -a /root/.config/wifi-fail2ban/cloudflare.credentials \
      /root/fail2ban-backups/cloudflare.credentials.before-sync; \
  fi'
```

复制凭据和脚本到临时路径：

```bash
scp -3 hongkong:/root/.config/wifi-fail2ban/cloudflare.credentials \
  <target>:/tmp/cloudflare.credentials.new
scp -3 hongkong:/root/.config/wifi-fail2ban/deployment.env \
  <target>:/tmp/deployment.env.new
scp -3 hongkong:/root/wifi-fail2ban-distribution/scripts/wifi_fail2ban.sh \
  <target>:/tmp/wifi_fail2ban.sh.new
scp -3 hongkong:/root/wifi-fail2ban-distribution/scripts/audit_fail2ban.sh \
  <target>:/tmp/audit_fail2ban.sh.new
```

由目标服务器 root 安装：

```bash
ssh <target> 'install -o root -g root -m 600 \
  /tmp/cloudflare.credentials.new \
  /root/.config/wifi-fail2ban/cloudflare.credentials; \
  install -o root -g root -m 600 \
  /tmp/deployment.env.new \
  /root/.config/wifi-fail2ban/deployment.env; \
  install -o root -g root -m 700 \
  /tmp/wifi_fail2ban.sh.new /home/Wi-Fi/wifi_fail2ban.sh; \
  install -o root -g root -m 700 \
  /tmp/audit_fail2ban.sh.new /root/audit_fail2ban.sh; \
  rm -f /tmp/cloudflare.credentials.new /tmp/deployment.env.new \
    /tmp/wifi_fail2ban.sh.new /tmp/audit_fail2ban.sh.new'
```

复制完成不等于应用。先确认目标服务器已通过宝塔安装 Fail2Ban、UFW 正常，并复核 `deployment.env` 是否适用于该服务器，再运行部署脚本。

## 安全边界

香港是凭据的维护主副本，但所有直接调用 Cloudflare 的目标服务器仍需要保存本地副本。因此任何一台目标服务器被入侵，都可能泄露当前 Global API Key。

如果要求 Key 只存在香港，需要另行设计认证后的封禁中继服务，让其他服务器只发送封禁请求，而不接触 Cloudflare凭据。这不属于当前复制式方案。
