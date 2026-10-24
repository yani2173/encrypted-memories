import contextlib
import io
import json
import unittest
import urllib.error
from unittest import mock

import require_merge_queue


class MergeQueueGuardTests(unittest.TestCase):
    def response(self, rules):
        return contextlib.closing(io.BytesIO(json.dumps(rules).encode()))

    def test_effective_main_queue_rule_is_required(self):
        with mock.patch("urllib.request.urlopen", return_value=self.response([
            {"type": "required_status_checks"}, {"type": "merge_queue"}
        ])) as request:
            require_merge_queue.require_queue("OnCloud-at/encrypted-memories")
        self.assertEqual(
            request.call_args.args[0].full_url,
            "https://api.github.com/repos/OnCloud-at/encrypted-memories/rules/branches/main",
        )

    def test_missing_queue_rule_fails_closed(self):
        with mock.patch("urllib.request.urlopen", return_value=self.response([
            {"type": "required_status_checks"}
        ])):
            with self.assertRaises(require_merge_queue.MergeQueueMissing):
                require_merge_queue.require_queue("OnCloud-at/encrypted-memories")

    def test_api_failure_fails_closed(self):
        error = urllib.error.HTTPError("https://api.github.com", 403, "Forbidden", {}, None)
        with mock.patch("urllib.request.urlopen", side_effect=error):
            with self.assertRaises(require_merge_queue.RulesUnavailable) as result:
                require_merge_queue.require_queue("OnCloud-at/encrypted-memories")
        self.assertIn("403", str(result.exception))

    def test_malformed_response_fails_closed(self):
        for value in [{"type": "merge_queue"}, [None], "merge_queue"]:
            with self.subTest(value=value):
                with mock.patch("urllib.request.urlopen", return_value=self.response(value)):
                    with self.assertRaises(require_merge_queue.RulesUnavailable):
                        require_merge_queue.require_queue("OnCloud-at/encrypted-memories")

    def test_invalid_json_fails_closed(self):
        with mock.patch("urllib.request.urlopen", return_value=contextlib.closing(io.BytesIO(b"invalid"))):
            with self.assertRaises(require_merge_queue.RulesUnavailable):
                require_merge_queue.require_queue("OnCloud-at/encrypted-memories")

    def test_network_failure_does_not_expose_request_data(self):
        with mock.patch("urllib.request.urlopen", side_effect=urllib.error.URLError("private request detail")):
            with self.assertRaises(require_merge_queue.RulesUnavailable) as result:
                require_merge_queue.require_queue("OnCloud-at/encrypted-memories")
        self.assertNotIn("private request detail", str(result.exception))

    def test_public_request_needs_no_write_permission_or_secret(self):
        with mock.patch.dict("os.environ", {}, clear=True):
            with mock.patch("urllib.request.urlopen", return_value=self.response([{"type": "merge_queue"}])) as request:
                require_merge_queue.require_queue("OnCloud-at/encrypted-memories")
        self.assertNotIn("Authorization", request.call_args.args[0].headers)


if __name__ == "__main__":
    unittest.main()
