#!/usr/bin/env python3
"""Exercise ownership, failure and secret-handling paths without network access."""

import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "wifi_cloudflare.py"
SPEC = importlib.util.spec_from_file_location("wifi_cloudflare", SCRIPT)
cf = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = cf
SPEC.loader.exec_module(cf)
TOKEN = "example-token-value-for-offline-tests-only"
ACCOUNT = "a" * 32
OWNER = "node-one"
JAIL = "vaultwarden"
ADDRESS = "203.0.113.9"
NOTES = f"Wi-Fi Fail2Ban {OWNER} {JAIL}"


def rule(identifier="1" * 32, notes=NOTES, mode="block", target="ip", value=ADDRESS):
    return {
        "id": identifier, "notes": notes, "mode": mode,
        "configuration": {"target": target, "value": value},
    }


class FakeClient:
    def __init__(self, rules=()):
        self.rules = list(rules)
        self.created = []
        self.deleted = []
        self.changed_rule = None

    def list_rules(self, target, address):
        return self.rules.copy()

    def create_rule(self, target, address, notes):
        self.created.append((target, address, notes))
        self.rules.append(rule(target=target, value=address, notes=notes))

    def get_rule(self, identifier):
        if self.changed_rule is not None:
            return self.changed_rule
        return next(item for item in self.rules if item["id"] == identifier)

    def delete_rule(self, identifier):
        self.deleted.append(identifier)
        self.rules = [item for item in self.rules if item["id"] != identifier]


class OwnershipTests(unittest.TestCase):
    def action(self, client, operation, address=ADDRESS, owner=OWNER):
        return cf.apply_action(client, operation, owner, JAIL, address)

    def test_repeated_ban_and_unban_are_idempotent(self):
        client = FakeClient()
        self.action(client, "ban")
        self.action(client, "ban")
        self.assertEqual(client.created, [("ip", ADDRESS, NOTES)])
        self.action(client, "unban")
        self.action(client, "unban")
        self.assertEqual(client.deleted, ["1" * 32])

    def test_unban_preserves_manual_other_owner_jail_mode_and_similar_notes(self):
        records = [
            rule("1" * 32), rule("2" * 32, notes="manual block"),
            rule("3" * 32, notes="Wi-Fi Fail2Ban node-two vaultwarden"),
            rule("4" * 32, notes="Wi-Fi Fail2Ban node-one sshd"),
            rule("5" * 32, notes=NOTES.lower()),
            rule("6" * 32, notes=NOTES + " extra"),
            rule("7" * 32, mode="whitelist"),
            rule("8" * 32, value="203.0.113.10"),
            rule("9" * 32, notes="Fail2Ban vaultwarden"),
        ]
        client = FakeClient(records)
        self.action(client, "unban")
        self.assertEqual(client.deleted, ["1" * 32])
        self.assertEqual(len(client.rules), 8)

    def test_ban_does_not_adopt_an_existing_unmanaged_rule(self):
        client = FakeClient([rule(notes="manual")])
        with self.assertRaisesRegex(cf.CloudflareError, "unmanaged"):
            self.action(client, "ban")
        self.assertEqual(client.created, [])
        self.assertEqual(client.deleted, [])

    def test_ipv6_uses_ip6_and_normalizes_equivalent_addresses(self):
        client = FakeClient()
        self.action(client, "ban", "2001:db8:0:0::1")
        self.assertEqual(client.created, [("ip6", "2001:db8::1", NOTES)])
        client.rules[0]["configuration"]["value"] = "2001:0db8:0000::1"
        self.action(client, "unban", "2001:db8::1")
        self.assertEqual(client.deleted, ["1" * 32])

    def test_invalid_ip_owner_and_shell_input_are_rejected_before_any_query(self):
        for address in ("203.0.113.0/24", "fe80::1%eth0", '$(touch /tmp/no)', "x"):
            with self.subTest(address=address):
                client = mock.Mock()
                with self.assertRaises(cf.CloudflareError):
                    self.action(client, "ban", address)
                client.list_rules.assert_not_called()
        client = mock.Mock()
        with self.assertRaises(cf.CloudflareError):
            self.action(client, "ban", owner="")
        client.list_rules.assert_not_called()

    def test_rule_changed_after_listing_is_not_deleted(self):
        client = FakeClient([rule()])
        client.changed_rule = rule(notes="manual")
        with self.assertRaisesRegex(cf.CloudflareError, "ownership changed"):
            self.action(client, "unban")
        self.assertEqual(client.deleted, [])

    def test_invalid_later_rule_id_prevents_all_deletions(self):
        client = FakeClient([rule(), rule("../other")])
        with self.assertRaisesRegex(cf.CloudflareError, "ID is invalid"):
            self.action(client, "unban")
        self.assertEqual(client.deleted, [])

    def test_uncertain_create_is_not_automatically_retried(self):
        client = FakeClient()
        client.create_rule = mock.Mock(side_effect=cf.CloudflareError("connection failed"))
        with self.assertRaises(cf.CloudflareError):
            self.action(client, "ban")
        client.create_rule.assert_called_once()


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.client = cf.CloudflareClient(cf.Credentials("token", ACCOUNT, TOKEN))

    def test_later_page_failure_prevents_all_mutations(self):
        for operation in ("ban", "unban"):
            with self.subTest(operation=operation):
                client = cf.CloudflareClient(cf.Credentials("token", ACCOUNT, TOKEN))
                client.request = mock.Mock(side_effect=[
                    {"success": True, "result": [rule()] * 50},
                    cf.CloudflareError("page two failed"),
                ])
                with self.assertRaisesRegex(cf.CloudflareError, "page two"):
                    cf.apply_action(client, operation, OWNER, JAIL, ADDRESS)
                self.assertEqual([call.args[0] for call in client.request.call_args_list], ["GET", "GET"])

    def test_pagination_does_not_require_total_pages(self):
        self.client.request = mock.Mock(side_effect=[
            {"success": True, "result": [rule()] * 50},
            {"success": True, "result": [rule("2" * 32)]},
        ])
        self.assertEqual(len(self.client.list_rules("ip", ADDRESS)), 51)
        self.assertEqual(self.client.request.call_args.kwargs["query"]["page"], 2)

    def test_server_page_size_is_used_and_page_numbers_are_checked(self):
        self.client.request = mock.Mock(side_effect=[
            {"success": True, "result": [rule()] * 20,
             "result_info": {"page": 1, "per_page": 20, "total_count": 21}},
            {"success": True, "result": [rule("2" * 32)],
             "result_info": {"page": 2, "per_page": 20, "total_count": 21}},
        ])
        self.assertEqual(len(self.client.list_rules("ip", ADDRESS)), 21)
        self.assertEqual(self.client.request.call_count, 2)
        self.client.request = mock.Mock(return_value={
            "success": True, "result": [], "result_info": {"page": 2, "per_page": 20},
        })
        with self.assertRaisesRegex(cf.CloudflareError, "page number"):
            self.client.list_rules("ip", ADDRESS)

    def test_http_error_does_not_expose_secret_or_response(self):
        self.client.opener.open = mock.Mock(side_effect=cf.HTTPError(
            "https://example.invalid/" + TOKEN, 403, TOKEN, {}, io.BytesIO(TOKEN.encode())
        ))
        with self.assertRaisesRegex(cf.CloudflareError, "HTTP 403") as caught:
            self.client.check()
        self.assertNotIn(TOKEN, str(caught.exception))

    def test_ipv6_list_omits_unsupported_target_query_filter(self):
        self.client.request = mock.Mock(return_value={"success": True, "result": []})
        self.client.list_rules("ip6", "2001:db8::1")
        query = self.client.request.call_args.kwargs["query"]
        self.assertNotIn("configuration.target", query)
        self.assertEqual(query["configuration.value"], "2001:db8::1")

    def test_bearer_header_account_scope_and_unsuccessful_response(self):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps({"success": False}).encode()
        self.client.opener.open = mock.Mock(return_value=response)
        with self.assertRaisesRegex(cf.CloudflareError, "did not confirm"):
            self.client.check()
        request = self.client.opener.open.call_args.args[0]
        self.assertEqual(request.headers["Authorization"], "Bearer " + TOKEN)
        self.assertIn("/accounts/" + ACCOUNT + "/firewall/access_rules/rules", request.full_url)
        self.assertNotIn(TOKEN, request.full_url)
        self.assertNotIn(TOKEN, repr(self.client.credentials))

    def test_redirect_is_refused(self):
        with self.assertRaisesRegex(cf.CloudflareError, "redirect refused"):
            cf.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.invalid")

    def test_mutation_results_must_confirm_the_expected_rule(self):
        self.client.request = mock.Mock(return_value={"success": True, "result": {}})
        with self.assertRaisesRegex(cf.CloudflareError, "create result"):
            self.client.create_rule("ip", ADDRESS, NOTES)
        with self.assertRaisesRegex(cf.CloudflareError, "delete result"):
            self.client.delete_rule("1" * 32)
        self.client.request = mock.Mock(return_value={"success": True, "result": rule()})
        self.client.create_rule("ip", ADDRESS, NOTES)
        self.client.request = mock.Mock(return_value={"success": True, "result": {"id": "1" * 32}})
        self.client.delete_rule("1" * 32)


class CredentialTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wifi-cloudflare-test-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "credentials"

    def load(self, raw, uid=0, mode=0o600, file_type=stat.S_IFREG):
        self.path.write_text(raw)
        metadata = SimpleNamespace(st_uid=uid, st_mode=file_type | mode)
        with mock.patch.object(cf.os, "fstat", return_value=metadata):
            return cf.load_credentials(self.path)

    def test_token_takes_priority_and_legacy_still_parses(self):
        legacy = "CF_EMAIL=admin@example.com\nCF_KEY=example-key-value-for-offline-tests\n"
        self.assertEqual(self.load(legacy).mode, "legacy")
        loaded = self.load(legacy + f"CF_API_TOKEN={TOKEN}\nCF_ACCOUNT_ID={ACCOUNT}\n")
        self.assertEqual(loaded.mode, "token")
        self.assertEqual(loaded.account_id, ACCOUNT)

    def test_bad_permissions_owner_file_type_and_duplicate_fields_are_rejected(self):
        good = f"CF_API_TOKEN={TOKEN}\nCF_ACCOUNT_ID={ACCOUNT}\n"
        for change in ({"uid": 501}, {"mode": 0o644}, {"file_type": stat.S_IFIFO}):
            with self.subTest(change=change), self.assertRaises(cf.CloudflareError):
                self.load(good, **change)
        for bad in (good + "CF_API_TOKEN=duplicate\n", "CF_API_TOKEN=" + TOKEN + "\n", good + "UNKNOWN=value\n"):
            with self.subTest(bad=bad), self.assertRaises(cf.CloudflareError):
                self.load(bad)

    def test_invalid_token_never_falls_back_to_legacy_credentials(self):
        raw = "CF_EMAIL=admin@example.com\nCF_KEY=example-key-value-for-offline-tests\n"
        with self.assertRaisesRegex(cf.CloudflareError, "CF_API_TOKEN"):
            self.load(raw + f"CF_API_TOKEN=invalid token\nCF_ACCOUNT_ID={ACCOUNT}\n")
        with self.assertRaisesRegex(cf.CloudflareError, "CF_API_TOKEN"):
            self.load(raw + "CF_API_TOKEN=\nCF_ACCOUNT_ID=\n")
        for extra in (
            " CF_API_TOKEN=" + TOKEN + "\n CF_ACCOUNT_ID=" + ACCOUNT + "\n",
            "CF_APITOKEN=" + TOKEN + "\n", "UNKNOWN=value\n",
        ):
            with self.subTest(extra=extra), self.assertRaisesRegex(cf.CloudflareError, "Invalid or duplicate"):
                self.load(raw + extra)

    def test_real_fifo_is_rejected_without_waiting_for_a_writer(self):
        os.mkfifo(self.path)
        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "mode", "--credentials", str(self.path)],
            capture_output=True, text=True, timeout=2,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("regular root-owned file", result.stderr)


if __name__ == "__main__":
    unittest.main()
