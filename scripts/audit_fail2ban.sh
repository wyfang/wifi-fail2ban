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
jail_status="$(fail2ban-client status)"
printf '%s\n' "${jail_status}"
active_jails="$(printf '%s\n' "${jail_status}" | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ')"

for jail_name in sshd ftpd recidive frps vaultwarden; do
    printf '\n[%s]\n' "${jail_name}"
    if ! [[ " ${active_jails} " =~ [[:space:]]${jail_name}[[:space:]] ]]; then
        printf 'not active; skipped\n'
        continue
    fi
    fail2ban-client status "${jail_name}" 2>&1 || true
    fail2ban-client get "${jail_name}" actions 2>&1 || true
done

printf '\n[managed files]\n'
for managed_path in \
    /etc/fail2ban/jail.d/90-wifi.local \
    /etc/fail2ban/filter.d/wifi-frps.conf \
    /etc/fail2ban/filter.d/wifi-vaultwarden.conf \
    /etc/fail2ban/action.d/wifi-cloudflare.conf \
    /usr/local/libexec/wifi-fail2ban/wifi_cloudflare.py \
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

printf '\n[Cloudflare credential mode]\n'
cf_helper=/usr/local/libexec/wifi-fail2ban/wifi_cloudflare.py
cf_credentials="${CREDENTIAL_FILE:-/root/.config/wifi-fail2ban/cloudflare.credentials}"
if [ -f "${cf_helper}" ] && [ -f "${cf_credentials}" ]; then
    cf_mode="$(/usr/bin/python3 "${cf_helper}" mode --credentials "${cf_credentials}")" \
        || fail "Cloudflare credential format or permissions are invalid"
    printf 'credential mode: %s\n' "${cf_mode}"
    if [ "${cf_mode}" = token ] && [ "${AUDIT_CLOUDFLARE_CHECK:-0}" = 1 ]; then
        /usr/bin/python3 "${cf_helper}" check --credentials "${cf_credentials}"
    else
        printf 'account API read check: skipped (set AUDIT_CLOUDFLARE_CHECK=1 for Token mode)\n'
    fi
else
    printf 'Token helper or credential file not installed\n'
fi

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
