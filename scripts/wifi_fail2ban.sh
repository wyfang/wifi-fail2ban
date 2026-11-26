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
MANAGED_CF_HELPER="/usr/local/libexec/wifi-fail2ban/wifi_cloudflare.py"
MANAGED_CF_ACTION="/etc/fail2ban/action.d/wifi-cloudflare.conf"
SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

changed=0
tmp_dir=""
cf_email=""
cf_key=""
cf_mode="legacy"
cf_helper_source=""
cf_action_source=""
cf_assets_ready=0

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
    local file_frps_findtime=""
    local file_frps_maxretry=""
    local file_frps_bantime=""
    local file_cf_rule_owner=""

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
                FRPS_FINDTIME) file_frps_findtime="${settings_value}" ;;
                FRPS_MAXRETRY) file_frps_maxretry="${settings_value}" ;;
                FRPS_BANTIME) file_frps_bantime="${settings_value}" ;;
                CF_RULE_OWNER) file_cf_rule_owner="${settings_value}" ;;
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
    [ "${FRPS_FINDTIME+x}" = "x" ] || FRPS_FINDTIME="${file_frps_findtime}"
    [ "${FRPS_MAXRETRY+x}" = "x" ] || FRPS_MAXRETRY="${file_frps_maxretry}"
    [ "${FRPS_BANTIME+x}" = "x" ] || FRPS_BANTIME="${file_frps_bantime}"
    [ "${CF_RULE_OWNER+x}" = "x" ] || CF_RULE_OWNER="${file_cf_rule_owner}"

    : "${MANUAL_IPS:=}"
    : "${FRPS_LOG:=/home/Wi-Fi/frps/logs/frps.log}"
    : "${VW_LOG:=/home/Wi-Fi/Bitwarden/data/log/vaultwarden.log}"
    : "${CREDENTIAL_FILE:=/root/.config/wifi-fail2ban/cloudflare.credentials}"
    : "${ENABLE_FRPS:=0}"
    : "${ENABLE_VAULTWARDEN:=auto}"
    : "${FRPS_FINDTIME:=600}"
    : "${FRPS_MAXRETRY:=3}"
    : "${FRPS_BANTIME:=86400}"
    : "${CF_RULE_OWNER:=}"

    validate_positive_integer FRPS_FINDTIME "${FRPS_FINDTIME}"
    validate_positive_integer FRPS_MAXRETRY "${FRPS_MAXRETRY}"
    validate_positive_integer FRPS_BANTIME "${FRPS_BANTIME}"
}

validate_positive_integer() {
    [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail "$1 must be a positive integer"
}

frps_connection_limit_enabled() {
    case "${ENABLE_FRPS}" in
        auto)
            warn "ENABLE_FRPS=auto now keeps the FRP connection counter disabled; normal connections do not prove authentication failures"
            return 1
            ;;
        1|yes|true|on)
            [ -f "${FRPS_LOG}" ] && [ -r "${FRPS_LOG}" ] \
                || fail "FRP connection counting requires a readable FRPS_LOG"
            warn "FRP connection counting is explicitly enabled: successful connections count, and UFW/recidive can block all ports"
            return 0
            ;;
        0|no|false|off) return 1 ;;
        *) fail "invalid ENABLE_FRPS; use 0 (disabled) or 1 (connection counting)" ;;
    esac
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

prepare_cloudflare_assets() {
    local support_file=""
    local support_owner=""
    local support_mode=""

    if [ -f "${SCRIPT_DIRECTORY}/wifi_cloudflare.py" ]; then
        cf_helper_source="${SCRIPT_DIRECTORY}/wifi_cloudflare.py"
    elif [ -f "${MANAGED_CF_HELPER}" ]; then
        cf_helper_source="${MANAGED_CF_HELPER}"
    fi
    if [ -f "${SCRIPT_DIRECTORY}/../config/wifi-cloudflare.conf" ]; then
        cf_action_source="${SCRIPT_DIRECTORY}/../config/wifi-cloudflare.conf"
    elif [ -f "${SCRIPT_DIRECTORY}/wifi-cloudflare.conf" ]; then
        cf_action_source="${SCRIPT_DIRECTORY}/wifi-cloudflare.conf"
    elif [ -f "${MANAGED_CF_ACTION}" ]; then
        cf_action_source="${MANAGED_CF_ACTION}"
    fi

    if [ -z "${cf_helper_source}" ] && [ -z "${cf_action_source}" ]; then
        return 0
    fi
    [ -n "${cf_helper_source}" ] && [ -n "${cf_action_source}" ] \
        || fail "Cloudflare support bundle is incomplete; install both helper and action template"
    for support_file in "${cf_helper_source}" "${cf_action_source}"; do
        support_owner="$(stat -c '%u' "${support_file}")"
        support_mode="$(stat -c '%a' "${support_file}")"
        [ "${support_owner}" = "0" ] \
            || fail "Cloudflare support files must be owned by root"
        case "${support_mode}" in
            400|500|600|644|700|755) ;;
            *) fail "Cloudflare support files must not be writable by group or others" ;;
        esac
    done
    [ -x /usr/bin/python3 ] || fail "Cloudflare support requires /usr/bin/python3"
    cf_assets_ready=1
}

validate_cloudflare_token_settings() {
    [[ "${CF_RULE_OWNER}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] \
        || fail "Token mode requires a stable, unique CF_RULE_OWNER in deployment.env"
    [[ "${CREDENTIAL_FILE}" =~ ^/[A-Za-z0-9_./-]+$ ]] \
        || fail "Token mode requires an absolute credential path without shell-special characters"
}

load_legacy_cloudflare_credentials() {
    local credential_line=""
    local credential_key=""
    local credential_value=""
    local seen_email=0
    local seen_key=0
    cf_email=""
    cf_key=""

    while IFS= read -r credential_line || [ -n "${credential_line}" ]; do
        credential_line="${credential_line%$'\r'}"
        case "${credential_line}" in
            ''|'#'*) continue ;;
            *=*) ;;
            *) fail "invalid Cloudflare credential line" ;;
        esac
        credential_key="${credential_line%%=*}"
        credential_value="${credential_line#*=}"
        case "${credential_key}" in
            CF_EMAIL)
                [ "${seen_email}" = 0 ] || fail "duplicate Cloudflare credential field"
                cf_email="${credential_value}"
                seen_email=1
                ;;
            CF_KEY)
                [ "${seen_key}" = 0 ] || fail "duplicate Cloudflare credential field"
                cf_key="${credential_value}"
                seen_key=1
                ;;
            CF_API_TOKEN|CF_ACCOUNT_ID)
                fail "Token credentials require the Cloudflare helper and action support files"
                ;;
            *) fail "unsupported Cloudflare credential field" ;;
        esac
    done < "${CREDENTIAL_FILE}"

    [[ "${cf_email}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] \
        || fail "invalid CF_EMAIL in ${CREDENTIAL_FILE}"
    [[ "${cf_key}" =~ ^[A-Za-z0-9_-]{20,}$ ]] \
        || fail "invalid CF_KEY in ${CREDENTIAL_FILE}"
}

load_cloudflare_credentials() {
    local credential_owner=""
    local credential_mode=""
    [ -f "${CREDENTIAL_FILE}" ] || return 1

    credential_owner="$(stat -c '%u' "${CREDENTIAL_FILE}")"
    credential_mode="$(stat -c '%a' "${CREDENTIAL_FILE}")"
    [ "${credential_owner}" = "0" ] || fail "Cloudflare credential file must be owned by root"
    case "${credential_mode}" in
        400|600) ;;
        *) fail "Cloudflare credential file must have mode 400 or 600" ;;
    esac

    if [ "${cf_assets_ready}" = "1" ]; then
        cf_mode="$(/usr/bin/python3 "${cf_helper_source}" mode --credentials "${CREDENTIAL_FILE}")" \
            || fail "Cloudflare credential validation failed"
        case "${cf_mode}" in
            token)
                validate_cloudflare_token_settings
                return 0
                ;;
            legacy) ;;
            *) fail "Cloudflare credential mode is invalid" ;;
        esac
    fi

    cf_mode="legacy"
    load_legacy_cloudflare_credentials
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
    if [ "${cf_mode}" = "token" ]; then
        /usr/bin/python3 "${cf_helper_source}" check --credentials "${CREDENTIAL_FILE}" \
            || fail "Cloudflare account rule read check failed; managed configuration was not installed"
        return 0
    fi
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

render_jail_config() {
    local frps_enabled="$1"
    local vaultwarden_enabled="$2"
    local credential_ready="$3"

    cat <<JAIL
[sshd]
action = %(action_)s
ignoreip = %(known/ignoreip)s ::1 ${MANUAL_IPS}

[ftpd]
action = %(action_)s
ignoreip = %(known/ignoreip)s ::1 ${MANUAL_IPS}

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
findtime = ${FRPS_FINDTIME}
maxretry = ${FRPS_MAXRETRY}
bantime = ${FRPS_BANTIME}
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
            if [ "${cf_mode}" = "token" ]; then
                validate_cloudflare_token_settings
                cat <<JAIL
      wifi-cloudflare[credential_file="${CREDENTIAL_FILE}", rule_owner="${CF_RULE_OWNER}"]
JAIL
            else
                cat <<JAIL
      cloudflare[cfuser="${cf_email}", cftoken="${cf_key}"]
JAIL
            fi
        fi
    else
        cat <<'JAIL'

[vaultwarden]
enabled = false
JAIL
    fi
}

render_service_logrotate() {
    local frps_log_present="$1"
    local vaultwarden_enabled="$2"

    if [ "${frps_log_present}" = "0" ] && [ "${vaultwarden_enabled}" = "0" ]; then
        return 0
    fi
    [ "${frps_log_present}" = "1" ] && printf '%s\n' "${FRPS_LOG}"
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
}

main() {
    local frps_log_present=0
    local vaultwarden_auto=0
    local frps_enabled=0
    local vaultwarden_enabled=0
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

    [ -f "${FRPS_LOG}" ] && frps_log_present=1
    has_vaultwarden && vaultwarden_auto=1
    frps_connection_limit_enabled && frps_enabled=1 || true
    toggle_enabled "${ENABLE_VAULTWARDEN}" "${vaultwarden_auto}" \
        && vaultwarden_enabled=1 || true

    prepare_cloudflare_assets
    if load_cloudflare_credentials; then
        credential_ready=1
    elif [ "${vaultwarden_enabled}" = "1" ]; then
        warn "Cloudflare credentials are missing; Vaultwarden will use local UFW protection only"
    fi
    if [ "${cf_mode}" = "token" ]; then
        verify_cloudflare
    fi

    tmp_dir="$(mktemp -d /tmp/wifi-fail2ban.XXXXXX)"
    config_root="${tmp_dir}/fail2ban"
    cp -a /etc/fail2ban "${config_root}"
    install -d -m 755 \
        "${config_root}/jail.d" \
        "${config_root}/filter.d" \
        "${config_root}/action.d"

    cat > "${tmp_dir}/wifi-frps.conf" <<'FILTER'
# Counts connections, including successful ones; never proves guest login failure.
# The corresponding jail is disabled unless ENABLE_FRPS=1 is explicitly selected.
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

    render_jail_config "${frps_enabled}" "${vaultwarden_enabled}" "${credential_ready}" \
        > "${tmp_dir}/90-wifi.local"

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

    render_service_logrotate "${frps_log_present}" "${vaultwarden_enabled}" \
        > "${tmp_dir}/wifi-services.logrotate"

    cat > "${tmp_dir}/wifi-fail2ban.tmpfiles" <<'TMPFILES'
f /var/log/fail2ban.log 0640 root adm -
TMPFILES

    install -o root -g root -m 644 "${tmp_dir}/wifi-frps.conf" \
        "${config_root}/filter.d/wifi-frps.conf"
    install -o root -g root -m 644 "${tmp_dir}/wifi-vaultwarden.conf" \
        "${config_root}/filter.d/wifi-vaultwarden.conf"
    install -o root -g root -m 600 "${tmp_dir}/90-wifi.local" \
        "${config_root}/jail.d/90-wifi.local"
    if [ "${cf_assets_ready}" = "1" ]; then
        install -o root -g root -m 644 "${cf_action_source}" \
            "${config_root}/action.d/wifi-cloudflare.conf"
    fi

    touch /var/log/fail2ban.log
    chown root:adm /var/log/fail2ban.log
    chmod 0640 /var/log/fail2ban.log

    log "testing the complete configuration before installation"
    fail2ban-client -c "${config_root}" -t

    if [ "${cf_assets_ready}" = "1" ]; then
        install_if_changed "${cf_helper_source}" "${MANAGED_CF_HELPER}" 700
        install_if_changed "${cf_action_source}" "${MANAGED_CF_ACTION}" 644
    fi
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

    if [ -s "${tmp_dir}/wifi-services.logrotate" ]; then
        install_if_changed "${tmp_dir}/wifi-services.logrotate" \
            "${MANAGED_SERVICE_LOGROTATE}" 644
    else
        remove_managed_if_present "${MANAGED_SERVICE_LOGROTATE}"
    fi

    fail2ban-client -t
    logrotate --debug /etc/logrotate.conf >/dev/null 2>&1
    systemd-tmpfiles --create "${MANAGED_TMPFILES}"
    [ "${cf_mode}" = "token" ] || verify_cloudflare

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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
