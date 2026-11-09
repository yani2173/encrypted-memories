#!/usr/bin/env python3
"""List test cases that passed on their retry from an xcresult tests JSON."""
import json
import sys


def has_failed_run(node: dict) -> bool:
    """Return True if the node or any descendant child is a failed run."""
    for child in node.get("children", []):
        if child.get("result") == "Failed" or has_failed_run(child):
            return True
    return False


def main() -> int:
    tree = json.load(sys.stdin)
    retried = []

    def walk(node: dict) -> None:
        if node.get("nodeType") == "Test Case" and node.get("result") == "Passed" and has_failed_run(node):
            retried.append(node["name"])
        for child in node.get("children", []):
            walk(child)

    for test_node in tree.get("testNodes", []):
        walk(test_node)

    if retried:
        print("Passed on its retry:")
        for name in retried:
            print(f"- {name}")
    else:
        print("No test passed only on its retry.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
