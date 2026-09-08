# Wi-Fi Fail2Ban

Maintain baseline Fail2Ban protection and FRP, Vaultwarden, and Cloudflare extensions on BT Panel servers.

[Maintenance guide](./docs/maintenance.md) · [简体中文](./README.md)

## Features

- Preserve BT Panel's management of SSH, FTP, and `/etc/fail2ban/jail.local`.
- Maintain repeat-offender, FRP, and Vaultwarden protection in separate configuration files.
- Ban Vaultwarden attackers through both local UFW and Cloudflare.
- Provide repeatable deployment scripts without duplicate rules or clearing the ban database.
- Provide a read-only audit script and maintenance, recovery, and security documentation.

## Usage

For Debian/Ubuntu servers using systemd, UFW, and the BT Panel Fail2Ban plugin. Install and start Fail2Ban through the panel before deployment.

```bash
sudo install -D -o root -g root -m 700 \
  scripts/wifi_fail2ban.sh /home/Wi-Fi/wifi_fail2ban.sh
sudo /home/Wi-Fi/wifi_fail2ban.sh
```

Pass server-specific allowlisted addresses through `MANUAL_IPS`, and keep Cloudflare credentials in root-only files. Do not commit real values. See [security and credentials](./docs/security.md) for formats.

## Notes

### Management boundaries

BT Panel continues to own `/etc/fail2ban/jail.local`. This project generates `/etc/fail2ban/jail.d/90-wifi.local` and files prefixed with `wifi-`. The panel may only display the basic jails it supports.

The script reads local security logs and calls the Cloudflare API when a Vaultwarden ban is triggered. It does not upload logs, save copies of the ban database, or change application log ownership. Configuration is tested in a temporary copy with `fail2ban-client -t` before writing to the live configuration directory. Fail2Ban is reloaded when configuration changes; unchanged runs do not operate on the service.

### Related documentation

- [Current baseline](./docs/current-baseline.md)
- [Rules](./docs/rules.md)
- [Panel integration and load order](./docs/panel-integration.md)
- [Hong Kong distribution source and multi-server synchronization](./docs/distribution.md)
- [Deployment, updates, and recovery](./docs/maintenance.md)
- [Security and credentials](./docs/security.md)

## License

This project currently has no open-source license. All rights are reserved unless otherwise stated in writing. Fail2Ban, UFW, Cloudflare, and other third-party software and services retain their own terms. See [scope of rights](./LICENSE_SCOPE.md).
