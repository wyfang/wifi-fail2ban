#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Wi-Fi Fail2Ban extension for servers managed by the aaPanel/BT plugin.
# The panel-owned /etc/fail2ban/jail.local is intentionally left untouched.

SETTINGS_FILE="${SETTINGS_FILE:-/root/.config/wifi-fail2ban/deployment.env}"
ALLOW_NON_BT="${ALLOW_NON_BT:-0}"
VERIFY_CLOUDFLARE="${VERIFY_CLOUDFLARE:-1}"

MANAGED_JAIL="/etc/fail2ban/jail.d/90-wifi.local"
MANAGED_FRPS_FILTER="/etc/fail2ban/filter.d/wifi-frps.conf"
MANAGED_VW_FILTER="/etc/fail2ban/filter.d/wifi-vaultwarden.conf"
MANAGED_F2B_LOGROTATE="/etc/logrotate.d/wifi-fail2ban"
MANAGED_SERVICE_LOGROTATE="/etc/logrotate.d/wifi-services"
MANAGED_TMPFILES="/etc/tmpfiles.d/wifi-fail2ban.conf"

changed=0
tmp_dir=""
cf_email=""
cf_key=""

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "${tmp_dir}" ] && [ -d "${tmp_dir}" ]; then
        rm -rf -- "${tmp_dir}"
    fi
}

trap cleanup EXIT

require_root() {
    [ "${EUID}" -eq 0 ] || fail "please run as root"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

configure_runtime() {
    local settings_line=""
    local settings_key=""
    local settings_value=""
    local settings_owner=""
    local settings_mode=""
    local file_manual_ips=""
    local file_frps_log=""
    local file_vw_log=""
    local file_credential_file=""
    local file_enable_frps=""
    local file_enable_vaultwarden=""

    if [ -f "${SETTINGS_FILE}" ]; then
        settings_owner="$(stat -c '%u' "${SETTINGS_FILE}")"
        settings_mode="$(stat -c '%a' "${SETTINGS_FILE}")"
        [ "${settings_owner}" = "0" ] \
            || fail "${SETTINGS_FILE} must be owned by root"
        case "${settings_mode}" in
            400|600) ;;
            *) fail "${SETTINGS_FILE} must have mode 400 or 600" ;;
        esac

        while IFS= read -r settings_line || [ -n "${settings_line}" ]; do
            settings_line="${settings_line%$'\r'}"
            case "${settings_line}" in
                ''|'#'*) continue ;;
                *=*) ;;
                *) fail "invalid line in ${SETTINGS_FILE}: ${settings_line}" ;;
            esac

            settings_key="${settings_line%%=*}"
            settings_value="${settings_line#*=}"
            case "${settings_key}" in
                MANUAL_IPS) file_manual_ips="${settings_value}" ;;
                FRPS_LOG) file_frps_log="${settings_value}" ;;
                VW_LOG) file_vw_log="${settings_value}" ;;
                CREDENTIAL_FILE) file_credential_file="${settings_value}" ;;
                ENABLE_FRPS) file_enable_frps="${settings_value}" ;;
                ENABLE_VAULTWARDEN) file_enable_vaultwarden="${settings_value}" ;;
                *) fail "unsupported setting in ${SETTINGS_FILE}: ${settings_key}" ;;
            esac
        done < "${SETTINGS_FILE}"
    fi

    [ "${MANUAL_IPS+x}" = "x" ] || MANUAL_IPS="${file_manual_ips}"
    [ "${FRPS_LOG+x}" = "x" ] || FRPS_LOG="${file_frps_log}"
    [ "${VW_LOG+x}" = "x" ] || VW_LOG="${file_vw_log}"
    [ "${CREDENTIAL_FILE+x}" = "x" ] || CREDENTIAL_FILE="${file_credential_file}"
    [ "${ENABLE_FRPS+x}" = "x" ] || ENABLE_FRPS="${file_enable_frps}"
    [ "${ENABLE_VAULTWARDEN+x}" = "x" ] || ENABLE_VAULTWARDEN="${file_enable_vaultwarden}"

    : "${MANUAL_IPS:=}"
    : "${FRPS_LOG:=/home/Wi-Fi/frps/logs/frps.log}"
    : "${VW_LOG:=/home/Wi-Fi/Bitwarden/data/log/vaultwarden.log}"
    : "${CREDENTIAL_FILE:=/root/.config/wifi-fail2ban/cloudflare.credentials}"
    : "${ENABLE_FRPS:=auto}"
    : "${ENABLE_VAULTWARDEN:=auto}"
}

toggle_enabled() {
    local value="$1"
    local auto_result="$2"

    case "${value}" in
        1|yes|true|on) return 0 ;;
        0|no|false|off) return 1 ;;
        auto) [ "${auto_result}" = "1" ] ;;
        *) fail "invalid toggle '${value}'; use auto/1/0" ;;
    esac
}

has_vaultwarden() {
    [ -f "${VW_LOG}" ] && return 0
    [ -e /home/Wi-Fi/Bitwarden/data/db.sqlite3 ] && return 0
    [ -e /home/Wi-Fi/Bitwarden/data/config.json ] && return 0
    [ -e /home/Wi-Fi/Bitwarden/docker-compose.yml ] && return 0
    [ -e /home/Wi-Fi/Bitwarden/compose.yml ] && return 0

    if command -v docker >/dev/null 2>&1; then
        docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null \
            | grep -Eiq 'vaultwarden|bitwardenrs|bitwarden_rs' && return 0
    fi

    return 1
}

load_cloudflare_credentials() {
    [ -f "${CREDENTIAL_FILE}" ] || return 1

    cf_email="$(sed -n 's/^CF_EMAIL=//p' "${CREDENTIAL_FILE}" | tail -n 1)"
    cf_key="$(sed -n 's/^CF_KEY=//p' "${CREDENTIAL_FILE}" | tail -n 1)"

    [[ "${cf_email}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] \
        || fail "invalid CF_EMAIL in ${CREDENTIAL_FILE}"
    [[ "${cf_key}" =~ ^[A-Za-z0-9_-]{20,}$ ]] \
        || fail "invalid CF_KEY in ${CREDENTIAL_FILE}"
}

install_if_changed() {
    local source_path="$1"
    local destination_path="$2"
    local mode="$3"

    install -d -m 755 "$(dirname "${destination_path}")"

    if [ -f "${destination_path}" ] && cmp -s "${source_path}" "${destination_path}"; then
        chown root:root "${destination_path}"
        chmod "${mode}" "${destination_path}"
        return 0
    fi

    install -o root -g root -m "${mode}" "${source_path}" "${destination_path}"
    changed=1
}

remove_managed_if_present() {
    local destination_path="$1"

    if [ -e "${destination_path}" ]; then
        rm -f -- "${destination_path}"
        changed=1
    fi
}

verify_cloudflare() {
    local status_code

    [ "${VERIFY_CLOUDFLARE}" = "1" ] || return 0
    [ -n "${cf_email}" ] && [ -n "${cf_key}" ] || return 0

    status_code="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H "X-Auth-Email: ${cf_email}" \
        -H "X-Auth-Key: ${cf_key}" \
        'https://api.cloudflare.com/client/v4/user/firewall/access_rules/rules?per_page=1' \
        || true)"

    if [ "${status_code}" = "200" ]; then
        log "Cloudflare credential check succeeded"
    else
        warn "Cloudflare credential check returned HTTP ${status_code:-unavailable}"
    fi
}

main() {
    local frps_auto=0
    local vaultwarden_auto=0
    local frps_enabled=0
    local vaultwarden_enabled=0
    local regex_command=""
    local config_root=""
    local credential_ready=0

    require_root
    configure_runtime
    require_command fail2ban-client
    require_command systemctl
    require_command ufw
    require_command curl
    require_command logrotate
    require_command systemd-tmpfiles

    if [ ! -d /www/server/panel/plugin/fail2ban ] && [ "${ALLOW_NON_BT}" != "1" ]; then
        fail "the BT Fail2Ban plugin is not installed; set ALLOW_NON_BT=1 only for an intentional non-panel deployment"
    fi

    systemctl cat fail2ban >/dev/null 2>&1 \
        || fail "Fail2Ban service is not installed"
    ufw status 2>/dev/null | grep -q '^Status: active' \
        || fail "UFW is not active"

    [ -f "${FRPS_LOG}" ] && frps_auto=1
    has_vaultwarden && vaultwarden_auto=1
    toggle_enabled "${ENABLE_FRPS}" "${frps_auto}" && frps_enabled=1 || true
    toggle_enabled "${ENABLE_VAULTWARDEN}" "${vaultwarden_auto}" \
        && vaultwarden_enabled=1 || true

    if load_cloudflare_credentials; then
        credential_ready=1
    elif [ "${vaultwarden_enabled}" = "1" ]; then
        warn "Cloudflare credentials are missing; Vaultwarden will use local UFW protection only"
    fi

    tmp_dir="$(mktemp -d /tmp/wifi-fail2ban.XXXXXX)"
    config_root="${tmp_dir}/fail2ban"
    cp -a /etc/fail2ban "${config_root}"
    install -d -m 755 \
        "${config_root}/jail.d" \
        "${config_root}/filter.d"

    cat > "${tmp_dir}/wifi-frps.conf" <<'FILTER'
[Definition]
failregex = ^.*\[(Openwrt-ssh|Pve-ssh|WiFi-Windows)\] get a user connection \[<HOST>:[0-9]+\]
ignoreregex =
FILTER

    cat > "${tmp_dir}/wifi-vaultwarden.conf" <<'FILTER'
[Definition]
failregex = ^.*\[ERROR\] (?:Invalid admin token|Invalid TOTP code|Username or password is incorrect)[\.!].* IP: <HOST>.*$
            ^.*Failed login attempt from <HOST>.*$
            ^.*invalid password for user.*from <HOST>$
ignoreregex = ^.*GET /api/alive.*$
FILTER

    {
        cat <<JAIL
[sshd]
action = %(action_)s

[ftpd]
action = %(action_)s

[recidive]
enabled = true
filter = recidive
logpath = /var/log/fail2ban.log
backend = auto
ignoreip = 127.0.0.1/8 ::1 ${MANUAL_IPS}
findtime = 86400
maxretry = 2
bantime = 1209600
bantime.increment = true
bantime.factor = 2
bantime.max = 2592000
action = ufw
JAIL

        if [ "${frps_enabled}" = "1" ]; then
            cat <<JAIL

[frps]
enabled = true
filter = wifi-frps
logpath = ${FRPS_LOG}
backend = auto
ignoreip = 127.0.0.1/8 ::1 ${MANUAL_IPS}
findtime = 600
maxretry = 3
bantime = 86400
bantime.increment = true
bantime.factor = 2
bantime.max = 2592000
action = ufw
JAIL
        else
            cat <<'JAIL'

[frps]
enabled = false
JAIL
        fi

        if [ "${vaultwarden_enabled}" = "1" ]; then
            cat <<JAIL

[vaultwarden]
enabled = true
filter = wifi-vaultwarden
logpath = ${VW_LOG}
backend = auto
ignoreip = 127.0.0.1/8 ::1 ${MANUAL_IPS}
findtime = 600
maxretry = 3
bantime = 86400
bantime.increment = true
bantime.factor = 2
bantime.max = 2592000
action = ufw
JAIL

            if [ "${credential_ready}" = "1" ]; then
                cat <<JAIL
         cloudflare[cfuser="${cf_email}", cftoken="${cf_key}"]
JAIL
            fi
        else
            cat <<'JAIL'

[vaultwarden]
enabled = false
JAIL
        fi
    } > "${tmp_dir}/90-wifi.local"

    cat > "${tmp_dir}/wifi-fail2ban.logrotate" <<'LOGROTATE'
/var/log/fail2ban.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        /usr/bin/fail2ban-client flushlogs >/dev/null 2>&1 || true
    endscript
}
LOGROTATE

    {
        [ "${frps_enabled}" = "1" ] && printf '%s\n' "${FRPS_LOG}"
        [ "${vaultwarden_enabled}" = "1" ] && printf '%s\n' "${VW_LOG}"
        cat <<'LOGROTATE'
{
    su root root
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
LOGROTATE
    } > "${tmp_dir}/wifi-services.logrotate"

    cat > "${tmp_dir}/wifi-fail2ban.tmpfiles" <<'TMPFILES'
f /var/log/fail2ban.log 0640 root adm -
TMPFILES

    install -o root -g root -m 644 "${tmp_dir}/wifi-frps.conf" \
        "${config_root}/filter.d/wifi-frps.conf"
    install -o root -g root -m 644 "${tmp_dir}/wifi-vaultwarden.conf" \
        "${config_root}/filter.d/wifi-vaultwarden.conf"
    install -o root -g root -m 600 "${tmp_dir}/90-wifi.local" \
        "${config_root}/jail.d/90-wifi.local"

    touch /var/log/fail2ban.log
    chown root:adm /var/log/fail2ban.log
    chmod 0640 /var/log/fail2ban.log

    log "testing the complete configuration before installation"
    fail2ban-client -c "${config_root}" -t

    install_if_changed "${tmp_dir}/wifi-frps.conf" "${MANAGED_FRPS_FILTER}" 644
    install_if_changed "${tmp_dir}/wifi-vaultwarden.conf" "${MANAGED_VW_FILTER}" 644
    install_if_changed "${tmp_dir}/90-wifi.local" "${MANAGED_JAIL}" 600
    if [ -f /etc/logrotate.d/fail2ban ]; then
        remove_managed_if_present "${MANAGED_F2B_LOGROTATE}"
    else
        install_if_changed "${tmp_dir}/wifi-fail2ban.logrotate" \
            "${MANAGED_F2B_LOGROTATE}" 644
    fi
    install_if_changed "${tmp_dir}/wifi-fail2ban.tmpfiles" "${MANAGED_TMPFILES}" 644

    if [ "${frps_enabled}" = "1" ] || [ "${vaultwarden_enabled}" = "1" ]; then
        install_if_changed "${tmp_dir}/wifi-services.logrotate" \
            "${MANAGED_SERVICE_LOGROTATE}" 644
    else
        remove_managed_if_present "${MANAGED_SERVICE_LOGROTATE}"
    fi

    fail2ban-client -t
    logrotate --debug /etc/logrotate.conf >/dev/null 2>&1
    systemd-tmpfiles --create "${MANAGED_TMPFILES}"
    verify_cloudflare

    if [ "${changed}" = "1" ]; then
        if systemctl is-active --quiet fail2ban; then
            fail2ban-client reload --restart --all \
                || systemctl restart fail2ban
        else
            systemctl start fail2ban
        fi
    else
        log "managed files are unchanged; service reload is not required"
    fi

    fail2ban-client flushlogs >/dev/null

    fail2ban-client status recidive >/dev/null
    [ "${frps_enabled}" = "0" ] || fail2ban-client status frps >/dev/null
    [ "${vaultwarden_enabled}" = "0" ] || fail2ban-client status vaultwarden >/dev/null

    log "deployment completed successfully"
    fail2ban-client status
}

main "$@"
