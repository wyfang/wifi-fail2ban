#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v fail2ban-client >/dev/null 2>&1 \
    || fail "fail2ban-client is not installed"

printf '[panel]\n'
if [ -d /www/server/panel/plugin/fail2ban ]; then
    printf 'plugin: installed\n'
else
    printf 'plugin: missing\n'
fi

printf '\n[service]\n'
systemctl is-active fail2ban
systemctl is-enabled fail2ban
fail2ban-client -V
fail2ban-client -t

printf '\n[jails]\n'
fail2ban-client status

for jail_name in sshd ftpd recidive frps vaultwarden; do
    printf '\n[%s]\n' "${jail_name}"
    fail2ban-client status "${jail_name}" 2>&1 || true
    fail2ban-client get "${jail_name}" actions 2>&1 || true
done

printf '\n[managed files]\n'
for managed_path in \
    /etc/fail2ban/jail.d/90-wifi.local \
    /etc/fail2ban/filter.d/wifi-frps.conf \
    /etc/fail2ban/filter.d/wifi-vaultwarden.conf \
    /etc/logrotate.d/wifi-fail2ban \
    /etc/logrotate.d/wifi-services \
    /etc/tmpfiles.d/wifi-fail2ban.conf \
    /home/Wi-Fi/wifi_fail2ban.sh \
    /root/.config/wifi-fail2ban/cloudflare.credentials
do
    if [ -e "${managed_path}" ]; then
        stat -c '%n|%U:%G|%a|%s' "${managed_path}"
    else
        printf '%s|missing\n' "${managed_path}"
    fi
done

printf '\n[fail2ban log descriptor]\n'
main_pid="$(systemctl show fail2ban -p MainPID --value)"
if [ -n "${main_pid}" ] && [ "${main_pid}" != "0" ]; then
    for fd_path in /proc/"${main_pid}"/fd/*; do
        fd_target="$(readlink "${fd_path}" 2>/dev/null || true)"
        case "${fd_target}" in
            *fail2ban.log*) printf '%s -> %s\n' "${fd_path}" "${fd_target}" ;;
        esac
    done
fi
