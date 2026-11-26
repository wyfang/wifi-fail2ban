#!/usr/bin/env python3
"""Verify policy generation without root, live services, network or credentials."""

import configparser
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "wifi_fail2ban.sh"
RUNTIME_KEYS = (
    "SETTINGS_FILE", "MANUAL_IPS", "FRPS_LOG", "VW_LOG", "CREDENTIAL_FILE",
    "ENABLE_FRPS", "ENABLE_VAULTWARDEN", "FRPS_FINDTIME", "FRPS_MAXRETRY",
    "FRPS_BANTIME",
    "CF_RULE_OWNER",
)
PREPARE = r'''
source "$1"
# Only settings-file metadata is substituted; the production parser still runs.
stat() {
    if [[ "$*" == "-c %u $SETTINGS_FILE" || "$*" == "-c %u ${CREDENTIAL_FILE:-}" ]]; then
        printf '%s\n' "${TEST_SETTINGS_UID:-0}"
    elif [[ "$*" == "-c %a $SETTINGS_FILE" || "$*" == "-c %a ${CREDENTIAL_FILE:-}" ]]; then
        printf '%s\n' "${TEST_SETTINGS_MODE:-600}"
    else
        return 99
    fi
}
configure_runtime
'''
RENDER = r'''
frps_enabled=0
if frps_connection_limit_enabled; then frps_enabled=1; fi
render_jail_config "$frps_enabled" "${TEST_VAULTWARDEN_ENABLED:-1}" 0
'''


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wifi-fail2ban-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.frps_log = self.base / "frps.log"
        self.frps_log.write_text(
            "2026-01-01 12:00:00 [I] [Pve-ssh] get a user connection "
            "[203.0.113.9:50000]\n"
        )
        self.settings = self.base / "deployment.env"

    def run_script(self, code=RENDER, **values):
        env = os.environ.copy()
        for key in RUNTIME_KEYS:
            env.pop(key, None)
        env.update({
            "SETTINGS_FILE": str(self.settings),
            "FRPS_LOG": str(self.frps_log),
            "VW_LOG": str(self.base / "vaultwarden.log"),
            "MANUAL_IPS": "203.0.113.20/32 2001:db8::20/128",
            **values,
        })
        return subprocess.run(
            ["bash", "-c", PREPARE + code, "configuration-test", str(SCRIPT)],
            env=env, text=True, capture_output=True, timeout=10,
        )

    def parsed(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        policy = configparser.RawConfigParser()
        # Existing panel state must be overridden by the managed FRP section.
        policy.read_string("[frps]\nenabled = true\n[sshd]\nmaxretry = 5\n")
        policy.read_string(result.stdout)
        return policy

    def test_normal_connection_log_does_not_enable_default_policy(self):
        result = self.run_script()
        policy = self.parsed(result)
        self.assertFalse(policy.getboolean("frps", "enabled"))
        self.assertTrue(policy.getboolean("recidive", "enabled"))
        self.assertTrue(policy.getboolean("vaultwarden", "enabled"))
        self.assertEqual(policy.get("vaultwarden", "action"), "ufw")
        self.assertEqual(policy.getint("sshd", "maxretry"), 5)

    def test_legacy_auto_in_persistent_settings_is_disabled(self):
        self.settings.write_text("ENABLE_FRPS=auto\nENABLE_VAULTWARDEN=auto\n")
        result = self.run_script()
        self.assertFalse(self.parsed(result).getboolean("frps", "enabled"))
        self.assertIn("auto now keeps", result.stderr)

    def test_explicit_disabled_setting_overrides_old_enabled_panel_state(self):
        result = self.run_script(ENABLE_FRPS="0")
        self.assertFalse(self.parsed(result).getboolean("frps", "enabled"))

    def test_explicit_mode_applies_validated_custom_limits_and_warns(self):
        self.settings.write_text(
            "ENABLE_FRPS=1\nFRPS_FINDTIME=120\nFRPS_MAXRETRY=30\nFRPS_BANTIME=900\n"
        )
        result = self.run_script()
        policy = self.parsed(result)
        self.assertTrue(policy.getboolean("frps", "enabled"))
        self.assertEqual(policy.getint("frps", "findtime"), 120)
        self.assertEqual(policy.getint("frps", "maxretry"), 30)
        self.assertEqual(policy.getint("frps", "bantime"), 900)
        self.assertIn("successful connections count", result.stderr)
        self.assertIn("block all ports", result.stderr)

    def test_one_run_override_does_not_rewrite_persistent_settings(self):
        original = "ENABLE_FRPS=1\n"
        self.settings.write_text(original)
        result = self.run_script(ENABLE_FRPS="0")
        self.assertFalse(self.parsed(result).getboolean("frps", "enabled"))
        self.assertEqual(self.settings.read_text(), original)

    def test_explicit_mode_requires_an_existing_log(self):
        self.frps_log.unlink()
        result = self.run_script(ENABLE_FRPS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("readable FRPS_LOG", result.stderr)

    def test_invalid_limits_and_config_injection_fail_before_rendering(self):
        for key in ("FRPS_FINDTIME", "FRPS_MAXRETRY", "FRPS_BANTIME"):
            for value in ("0", "-1", "1.5", "auto", "3\n[sshd]\nenabled=false"):
                with self.subTest(key=key, value=value):
                    result = self.run_script(**{key: value})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("positive integer", result.stderr)

    def test_ssh_and_ftp_preserve_known_ignoreip_and_append_management_sources(self):
        policy = self.parsed(self.run_script())
        for jail in ("sshd", "ftpd"):
            self.assertEqual(
                policy.get(jail, "ignoreip"),
                "%(known/ignoreip)s ::1 203.0.113.20/32 2001:db8::20/128",
            )
        # Real expansion of known/ignoreip is verified with staged Fail2Ban on Linux.
        self.assertEqual(policy.get("sshd", "action"), "%(action_)s")
        self.assertEqual(policy.get("ftpd", "action"), "%(action_)s")

    def test_frp_log_rotation_survives_disabled_jail_and_is_deterministic(self):
        code = 'render_service_logrotate 1 0\n'
        first = self.run_script(code, ENABLE_FRPS="0")
        second = self.run_script(code, ENABLE_FRPS="0")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, second.stdout)
        self.assertIn(str(self.frps_log), first.stdout)
        self.assertNotIn("vaultwarden.log", first.stdout)
        self.assertIn("copytruncate", first.stdout)

    def test_no_service_logs_produces_no_managed_service_rotation(self):
        result = self.run_script('render_service_logrotate 0 0\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_token_action_uses_a_file_reference_and_preserves_local_ufw(self):
        result = self.run_script(
            'cf_mode=token\ncf_key=must-not-appear-in-token-config\nrender_jail_config 0 1 1\n',
            CF_RULE_OWNER="node-one", CREDENTIAL_FILE="/root/private/cloudflare.credentials",
        )
        policy = self.parsed(result)
        action = policy.get("vaultwarden", "action")
        self.assertTrue(action.startswith("ufw\n"))
        self.assertIn('wifi-cloudflare[credential_file="/root/private/cloudflare.credentials", rule_owner="node-one"]', action)
        self.assertNotIn("must-not-appear", result.stdout)
        self.assertNotIn("cftoken", result.stdout)
        self.assertFalse(policy.getboolean("frps", "enabled"))

    def test_legacy_action_is_preserved(self):
        result = self.run_script(
            'cf_mode=legacy\ncf_email=admin@example.com\n'
            'cf_key=example-key-value-for-offline-tests\nrender_jail_config 0 1 1\n'
        )
        action = self.parsed(result).get("vaultwarden", "action")
        self.assertIn('cloudflare[cfuser="admin@example.com", cftoken="example-key-value-for-offline-tests"]', action)
        self.assertNotIn("wifi-cloudflare", action)

    def test_token_mode_rejects_missing_owner_and_shell_special_paths(self):
        for values in ({"CF_RULE_OWNER": ""}, {"CF_RULE_OWNER": "node-one", "CREDENTIAL_FILE": '/root/$(id)'},
                       {"CF_RULE_OWNER": 'node\"\n[sshd]'}):
            with self.subTest(values=values):
                result = self.run_script('validate_cloudflare_token_settings\n', **values)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_legacy_credentials_work_without_a_token_support_bundle(self):
        credentials = self.base / "credentials"
        credentials.write_text("CF_EMAIL=admin@example.com\nCF_KEY=example-key-value-for-offline-tests\n")
        result = self.run_script(
            'cf_assets_ready=0\nload_cloudflare_credentials\nrender_jail_config 0 1 1\n',
            CREDENTIAL_FILE=str(credentials),
        )
        action = self.parsed(result).get("vaultwarden", "action")
        self.assertIn('cloudflare[cfuser="admin@example.com"', action)
        self.assertNotIn("wifi-cloudflare", action)

    def test_token_fields_require_the_support_bundle_and_do_not_use_old_key(self):
        credentials = self.base / "credentials"
        credentials.write_text(
            "CF_EMAIL=admin@example.com\nCF_KEY=example-key-value-for-offline-tests\n"
            "CF_API_TOKEN=example-token-for-offline-tests\nCF_ACCOUNT_ID=" + "a" * 32 + "\n"
        )
        result = self.run_script(
            'cf_assets_ready=0\nload_cloudflare_credentials\nrender_jail_config 0 1 1\n',
            CREDENTIAL_FILE=str(credentials), CF_RULE_OWNER="node-one",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("require the Cloudflare helper", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_available_helper_validates_even_apparently_legacy_credentials(self):
        credentials = self.base / "credentials"
        credentials.write_text("CF_EMAIL=admin@example.com\nCF_KEY=example-key-value-for-offline-tests\n")
        result = self.run_script(
            'cf_assets_ready=1\ncf_helper_source=offline-helper\n'
            '/usr/bin/python3() { printf "strict helper rejected the file\\n" >&2; return 1; }\n'
            'load_cloudflare_credentials\nrender_jail_config 0 1 1\n',
            CREDENTIAL_FILE=str(credentials),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("strict helper rejected", result.stderr)
        self.assertIn("credential validation failed", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_without_helper_unknown_misspelled_and_duplicate_fields_never_downgrade(self):
        credentials = self.base / "credentials"
        legacy = "CF_EMAIL=admin@example.com\nCF_KEY=example-key-value-for-offline-tests\n"
        invalid_lines = (
            " CF_API_TOKEN=example-token-for-offline-tests\n CF_ACCOUNT_ID=" + "a" * 32,
            "CF_APITOKEN=example-token-for-offline-tests",
            "UNEXPECTED=private-value-that-must-not-be-printed",
            "CF_KEY=duplicate-private-value-that-must-not-be-printed",
            "private-value-that-must-not-be-printed",
        )
        for extra in invalid_lines:
            with self.subTest(extra=extra):
                credentials.write_text(legacy + extra + "\n")
                result = self.run_script(
                    'cf_assets_ready=0\nload_cloudflare_credentials\nrender_jail_config 0 1 1\n',
                    CREDENTIAL_FILE=str(credentials),
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("private-value", result.stderr)
                self.assertNotIn("example-token-for-offline-tests", result.stderr)

    def test_valid_legacy_comments_crlf_and_no_final_newline_remain_compatible(self):
        credentials = self.base / "credentials"
        credentials.write_bytes(
            b"# old credential format\r\n\r\nCF_EMAIL=admin@example.com\r\n"
            b"CF_KEY=example-key-value-for-offline-tests"
        )
        result = self.run_script(
            'cf_assets_ready=0\nload_cloudflare_credentials\nprintf "%s\\n" "$cf_mode"\n',
            CREDENTIAL_FILE=str(credentials),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "legacy\n")


if __name__ == "__main__":
    unittest.main()
