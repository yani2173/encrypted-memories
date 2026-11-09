"""Tests for list_retried_tests.py, the retry listing of the Duo UI test job."""
import json
import pathlib
import subprocess
import sys
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent / "list_retried_tests.py"


def run_script(payload):
    return subprocess.run(
        [sys.executable, str(SCRIPT)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        check=True,
    )


def test_case(name, result, children=()):
    return {"nodeType": "Test Case", "name": name, "result": result, "children": list(children)}


def repetition(name, result, children=()):
    return {"nodeType": "Repetition", "name": name, "result": result, "children": list(children)}


def suite(children):
    return {"nodeType": "Test Suite", "name": "Class", "result": "Passed", "children": list(children)}


class ListRetriedTests(unittest.TestCase):
    def test_a_passed_test_case_with_a_failed_repetition_is_listed(self):
        node = test_case("testExample()", "Passed",
                         [repetition("First Run", "Failed"), repetition("Retry 1", "Passed")])
        self.assertEqual(run_script({"testNodes": [suite([node])]}).stdout,
                         "Passed on its retry:\n- testExample()\n")

    def test_a_passed_test_case_without_a_failed_repetition_is_not_listed(self):
        node = test_case("testExample()", "Passed", [repetition("First Run", "Passed")])
        self.assertEqual(run_script({"testNodes": [suite([node])]}).stdout,
                         "No test passed only on its retry.\n")

    def test_a_failed_test_case_is_not_listed_even_when_it_has_failed_repetitions(self):
        node = test_case("testExample()", "Failed",
                         [repetition("First Run", "Failed"), repetition("Retry 1", "Failed")])
        self.assertEqual(run_script({"testNodes": [suite([node])]}).stdout,
                         "No test passed only on its retry.\n")

    def test_a_failure_message_below_a_failed_repetition_is_found_recursively(self):
        # A failed repetition carries a Failure Message child, as the result bundle of
        # xcodebuild -retry-tests-on-failure does; the failure message itself has no result.
        failure = {"nodeType": "Failure Message", "name": "failed - deliberate", "result": None, "children": []}
        node = test_case("testExample()", "Passed",
                         [repetition("First Run", "Failed", [failure]), repetition("Retry 1", "Passed")])
        self.assertEqual(run_script({"testNodes": [suite([node])]}).stdout,
                         "Passed on its retry:\n- testExample()\n")

    def test_an_empty_tree_lists_nothing(self):
        self.assertEqual(run_script({"testNodes": []}).stdout,
                         "No test passed only on its retry.\n")


if __name__ == "__main__":
    unittest.main()
