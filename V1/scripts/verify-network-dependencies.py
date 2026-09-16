#!/usr/bin/env python3
"""Validate the Direct-only target boundary from SwiftPM's described package."""

import json
import sys


def validate(package):
    targets = {target["name"]: target for target in package["targets"]}
    core = targets["NotchHubCore"]
    if "NotchHubNetwork" not in core.get("product_dependencies", []):
        raise ValueError("NotchHubCore must depend on the shared NotchHubNetwork product")

    for entry in ("NotchHubLite", "NotchHubSafeFeatures"):
        pending = [entry]
        visited = set()
        while pending:
            name = pending.pop()
            if name in visited:
                continue
            visited.add(name)
            target = targets[name]
            if "NotchHubNetwork" in target.get("product_dependencies", []):
                raise ValueError(f"{entry} must not link NotchHubNetwork through {name}")
            pending.extend(target.get("target_dependencies", []))


try:
    validate(json.load(sys.stdin))
except (KeyError, ValueError, TypeError) as error:
    print(f"Network dependency boundary failed: {error}", file=sys.stderr)
    raise SystemExit(1) from error
