#!/usr/bin/env python3
"""Account-scoped Cloudflare IP Access Rules for a Fail2Ban action.

Secrets are read from a root-only file and never passed as command arguments.
Only exact IP/block rules carrying this action's notes are removed.
"""

import argparse
from dataclasses import dataclass, field
import ipaddress
import json
import os
import re
import stat
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener


API_ROOT = "https://api.cloudflare.com/client/v4"
DEFAULT_CREDENTIALS = "/root/.config/wifi-fail2ban/cloudflare.credentials"
MAX_RESPONSE_BYTES = 1024 * 1024


class CloudflareError(Exception):
    """An error safe to display without credential values or response bodies."""


@dataclass(frozen=True)
class Credentials:
    mode: str
    account_id: str = ""
    token: str = field(default="", repr=False)


def load_credentials(path):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "r", encoding="utf-8") as stream:
            metadata = os.fstat(stream.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0:
                raise CloudflareError("Credential file must be a regular root-owned file")
            if stat.S_IMODE(metadata.st_mode) not in (0o400, 0o600):
                raise CloudflareError("Credential file must have mode 400 or 600")
            raw = stream.read(16385)
    except (OSError, UnicodeError):
        raise CloudflareError("Cannot securely read credential file") from None
    if len(raw) > 16384:
        raise CloudflareError("Credential file is too large")

    values = {}
    allowed = {"CF_API_TOKEN", "CF_ACCOUNT_ID", "CF_EMAIL", "CF_KEY"}
    for line in raw.splitlines():
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or key not in allowed or key in values:
            raise CloudflareError("Invalid or duplicate credential field")
        values[key] = value

    token = values.get("CF_API_TOKEN", "")
    account = values.get("CF_ACCOUNT_ID", "")
    if "CF_API_TOKEN" in values or "CF_ACCOUNT_ID" in values:
        if not re.fullmatch(r"[A-Za-z0-9_-]{20,}", token):
            raise CloudflareError("Invalid CF_API_TOKEN")
        if not re.fullmatch(r"[a-fA-F0-9]{32}", account):
            raise CloudflareError("CF_ACCOUNT_ID must be a 32-character account ID")
        return Credentials("token", account.lower(), token)

    email = values.get("CF_EMAIL", "")
    key = values.get("CF_KEY", "")
    if not re.fullmatch(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+", email):
        raise CloudflareError("Invalid CF_EMAIL")
    if not re.fullmatch(r"[A-Za-z0-9_-]{20,}", key):
        raise CloudflareError("Invalid CF_KEY")
    return Credentials("legacy")


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise CloudflareError("Cloudflare API redirect refused")


class CloudflareClient:
    def __init__(self, credentials):
        if credentials.mode != "token":
            raise CloudflareError("Account API action requires CF_API_TOKEN and CF_ACCOUNT_ID")
        self.credentials = credentials
        self.base_path = f"/accounts/{credentials.account_id}/firewall/access_rules/rules"
        self.opener = build_opener(NoRedirect())
        self.deadline = time.monotonic() + 45

    def request(self, method, path, body=None, query=None):
        url = API_ROOT + path
        if query:
            url += "?" + urlencode(query)
        payload = None if body is None else json.dumps(body).encode("utf-8")
        request = Request(url, data=payload, method=method, headers={
            "Authorization": f"Bearer {self.credentials.token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "wifi-fail2ban",
        })
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise CloudflareError("Cloudflare action exceeded its time limit")
        try:
            with self.opener.open(request, timeout=min(10, remaining)) as response:
                raw = response.read(MAX_RESPONSE_BYTES + 1)
        except HTTPError as error:
            status = error.code
            error.close()
            raise CloudflareError(f"Cloudflare API returned HTTP {status}") from None
        except (URLError, OSError, TimeoutError):
            raise CloudflareError("Cloudflare API connection failed") from None
        if len(raw) > MAX_RESPONSE_BYTES:
            raise CloudflareError("Cloudflare API response exceeded the size limit")
        try:
            result = json.loads(raw)
        except (ValueError, UnicodeError):
            raise CloudflareError("Cloudflare API returned invalid JSON") from None
        if not isinstance(result, dict) or result.get("success") is not True:
            raise CloudflareError("Cloudflare API did not confirm success")
        return result

    def check(self):
        result = self.request("GET", self.base_path, query={"per_page": 1})
        if not isinstance(result.get("result"), list):
            raise CloudflareError("Cloudflare account rule list is invalid")

    def list_rules(self, target, address):
        rules = []
        for page in range(1, 101):
            query = {
                "configuration.value": address,
                "mode": "block", "per_page": 50, "page": page,
            }
            # The list endpoint does not document ip6 in its target query enum.
            # IPv6 is still checked precisely against returned configurations.
            if target == "ip":
                query["configuration.target"] = target
            result = self.request("GET", self.base_path, query=query)
            batch = result.get("result")
            if not isinstance(batch, list) or any(not isinstance(item, dict) for item in batch):
                raise CloudflareError("Cloudflare account rule list is invalid")
            info = result.get("result_info")
            if info is None:
                info = {}
            if not isinstance(info, dict):
                raise CloudflareError("Cloudflare rule pagination is invalid")
            page_size = info.get("per_page", 50)
            if isinstance(page_size, bool) or not isinstance(page_size, int) \
                    or not 1 <= page_size <= 1000 or len(batch) > page_size:
                raise CloudflareError("Cloudflare rule page size is invalid")
            if "page" in info and (isinstance(info["page"], bool) or info["page"] != page):
                raise CloudflareError("Cloudflare rule page number is invalid")
            rules.extend(batch)
            # Filtered lists do not consistently include total_pages/total_count.
            if len(batch) < page_size:
                return rules
        raise CloudflareError("Cloudflare rule pagination exceeded the limit")

    def create_rule(self, target, address, notes):
        result = self.request("POST", self.base_path, {
            "mode": "block", "configuration": {"target": target, "value": address},
            "notes": notes,
        }).get("result")
        if not isinstance(result, dict) or not isinstance(result.get("id"), str) \
                or not re.fullmatch(r"[a-fA-F0-9]{32}", result["id"]) \
                or result.get("notes") != notes or not rule_matches(result, target, address):
            raise CloudflareError("Cloudflare create result is invalid; recheck rules before retrying")

    def delete_rule(self, identifier):
        if not isinstance(identifier, str) or not re.fullmatch(r"[a-fA-F0-9]{32}", identifier):
            raise CloudflareError("Cloudflare rule ID is invalid")
        result = self.request("DELETE", self.base_path + "/" + identifier).get("result")
        if not isinstance(result, dict) or result.get("id") != identifier:
            raise CloudflareError("Cloudflare delete result is invalid; recheck rules before retrying")

    def get_rule(self, identifier):
        if not isinstance(identifier, str) or not re.fullmatch(r"[a-fA-F0-9]{32}", identifier):
            raise CloudflareError("Cloudflare rule ID is invalid")
        result = self.request("GET", self.base_path + "/" + identifier).get("result")
        if not isinstance(result, dict):
            raise CloudflareError("Cloudflare account rule is invalid")
        return result


def rule_matches(rule, target, address):
    configuration = rule.get("configuration")
    if not isinstance(configuration, dict) or rule.get("mode") != "block":
        return False
    if configuration.get("target") != target:
        return False
    value = configuration.get("value", "")
    if not isinstance(value, str) or "%" in value:
        return False
    try:
        return str(ipaddress.ip_address(value)) == address
    except ValueError:
        return False


def apply_action(client, operation, owner, jail, raw_address):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", owner):
        raise CloudflareError("Invalid or missing rule owner")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", jail):
        raise CloudflareError("Invalid jail name")
    if "%" in raw_address:
        raise CloudflareError("Scoped IPv6 addresses are not supported")
    try:
        address = ipaddress.ip_address(raw_address)
    except ValueError:
        raise CloudflareError("Invalid source IP") from None
    target = "ip" if address.version == 4 else "ip6"
    canonical = str(address)
    notes = f"Wi-Fi Fail2Ban {owner} {jail}"
    rules = client.list_rules(target, canonical)
    matching = [rule for rule in rules if rule_matches(rule, target, canonical)]
    owned = [rule for rule in matching if rule.get("notes") == notes]

    if operation == "ban":
        if owned:
            return "Cloudflare managed block already exists"
        if matching:
            raise CloudflareError("IP already has an unmanaged Cloudflare block; it was left unchanged")
        client.create_rule(target, canonical, notes)
        return "Cloudflare managed block created"
    if operation != "unban":
        raise CloudflareError("Invalid operation")
    # Validate every ID before deleting anything, and never delete by IP alone.
    for rule in owned:
        if not isinstance(rule.get("id"), str) or not re.fullmatch(r"[a-fA-F0-9]{32}", rule["id"]):
            raise CloudflareError("Cloudflare managed rule ID is invalid")
    removed = 0
    for rule in owned:
        try:
            current = client.get_rule(rule["id"])
            if current.get("id") != rule["id"] or current.get("notes") != notes \
                    or not rule_matches(current, target, canonical):
                raise CloudflareError("Cloudflare rule ownership changed; deletion refused")
            client.delete_rule(rule["id"])
            removed += 1
        except CloudflareError as error:
            raise CloudflareError(f"{error}; managed blocks already removed: {removed}") from None
    return f"Cloudflare managed blocks removed: {removed}"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("mode", "check", "ban", "unban"))
    parser.add_argument("--credentials", default=DEFAULT_CREDENTIALS)
    parser.add_argument("--jail", default="")
    parser.add_argument("--owner", default="")
    parser.add_argument("--ip", default="")
    args = parser.parse_args(argv)
    try:
        credentials = load_credentials(args.credentials)
        if args.operation == "mode":
            print(credentials.mode)
            return 0
        client = CloudflareClient(credentials)
        if args.operation == "check":
            client.check()
            print("Cloudflare account rule read check succeeded; write permission not tested")
        else:
            print(apply_action(client, args.operation, args.owner, args.jail, args.ip))
        return 0
    except CloudflareError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
