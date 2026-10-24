#!/usr/bin/env python3
"""Compare effective Keychain groups with the last supported stable source."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess


class EntitlementError(ValueError):
    """The update changes the Keychain access contract."""


def compare_groups(previous, current):
    changed = [name for name in sorted(previous.keys() | current.keys())
               if previous.get(name) != current.get(name)]
    if changed:
        raise EntitlementError("Keychain access groups changed: " + ", ".join(changed))


def snapshot(root, revision=None):
    def read(path):
        if revision:
            return subprocess.check_output(["git", "show", revision + ":" + path], cwd=root)
        return (root / path).read_bytes()
    # Parse XcodeGen configuration and entitlement plists, rather than searching source text.
    project = json.loads(subprocess.check_output([
        "ruby", "-ryaml", "-rjson", "-e",
        "print JSON.generate(YAML.safe_load(STDIN.read, aliases: true))"],
        input=read("project.yml").decode(), text=True))
    result = {}
    for target, platform in [("EncryptedMemories", "macOS"), ("EncryptedMemoriesMobile", "iOS")]:
        settings = {}
        for owner in [project, project["targets"][target]]:
            config = owner.get("settings", {})
            settings.update(config.get("base", {}))
            settings.update(config.get("configs", {}).get("Release", {}))
        bundle = settings["PRODUCT_BUNDLE_IDENTIFIER"]
        path = settings.get("CODE_SIGN_ENTITLEMENTS")
        name = f"{platform}: {path or 'project.yml (implicit group)'}"
        groups = []
        if path:
            entitlements = plistlib.loads(read(path))
            groups = entitlements.get("keychain-access-groups", [])
            if not isinstance(groups, list) or not all(isinstance(group, str) for group in groups):
                raise EntitlementError(f"Invalid Keychain access groups: {path}")
        effective = groups or ["$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"]
        result[name] = sorted(group.replace("$(PRODUCT_BUNDLE_IDENTIFIER)", bundle) for group in effective)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("previous", type=Path)
    parser.add_argument("current", type=Path)
    args = parser.parse_args()
    try:
        compare_groups(snapshot(args.previous), snapshot(args.current))
    except (EntitlementError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Release Keychain check failed: {error}")
