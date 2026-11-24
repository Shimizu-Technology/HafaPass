import io
import os
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

sys.path.insert(0, os.path.dirname(__file__))
import fetch_ops_summary as script  # noqa: E402

SUMMARY = {
    "guam_date": "2027-01-05", "generated_at": "2027-01-06T01:00:00Z", "revision": "abcdef123456",
    "window": {"partial": False},
    "sales": {"orders": 2, "tickets": 3, "gross_cents": 2900, "refund_cents": 500, "refund_count": 1,
              "fees_cents": {"platform": 200, "processing": 160, "tax": 0, "organizer": 0},
              "door_cash": {"orders": 1, "gross_cents": 1200}, "online": {"orders": 1, "gross_cents": 1700}},
    "events": [{"title": "Copa de Marianas", "orders": 2, "tickets": 3, "gross_cents": 2900, "refund_cents": 500,
                "door_cash_gross_cents": 1200}],
    "on_sale": [{"title": "Copa de Marianas", "max_capacity": 900, "capacity_remaining": 212,
                 "ticket_types": [{"name": "Adult", "remaining": 100}]}],
    "health": {"readiness": "ready",
               "stripe_webhooks": {"silent": False, "failing": False, "last_receipt_at": "2027-01-05T22:00:00Z",
                                   "receipts_last_hour": 4, "failed_total": 0},
               "operational_signals": {"failed_background_jobs": 0, "stripe_webhooks_silent": 0},
               "job_queue": {"available": True, "ready": 0, "claimed": 1, "failed": 0, "oldest_ready_age_seconds": 0}},
}


class RenderTest(unittest.TestCase):
    def test_all_clear_markdown(self):
        text = script.render(SUMMARY)
        self.assertIn("## All clear", text)
        self.assertIn("Gross: $29.00 (online $17.00 in 1 orders, door cash $12.00 in 1)", text)
        self.assertIn("212 of 900 left (Adult 100)", text)

    def test_problems_are_listed(self):
        bad = {**SUMMARY, "health": {**SUMMARY["health"], "readiness": "not_ready",
               "stripe_webhooks": {**SUMMARY["health"]["stripe_webhooks"], "silent": True},
               "operational_signals": {"failed_background_jobs": 2}}}
        text = script.render(bad)
        self.assertIn("## Needs attention", text)
        self.assertIn("Readiness is not_ready", text)
        self.assertIn("Stripe webhooks look silent", text)
        self.assertIn("failed background jobs: 2", text)


class MainTest(unittest.TestCase):
    def run_main(self, env, argv=()):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, env, clear=True), redirect_stdout(out), redirect_stderr(err):
            code = script.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_requires_configuration_and_https(self):
        self.assertEqual(self.run_main({})[0], 2)
        code, _, err = self.run_main({"OPS_SUMMARY_URL": "http://example.com", "OPS_SUMMARY_TOKEN": "x" * 40})
        self.assertEqual(code, 2)
        self.assertIn("https", err)

    def test_prints_markdown_and_never_the_token(self):
        token = "t" * 40
        with mock.patch.object(script, "fetch", return_value=SUMMARY) as fetch:
            code, out, err = self.run_main({"OPS_SUMMARY_URL": "https://api.example.com", "OPS_SUMMARY_TOKEN": token}, ["--date", "today"])
        self.assertEqual(code, 0)
        fetch.assert_called_once_with("https://api.example.com", token, "today")
        self.assertNotIn(token, out + err)

    def test_http_error_message_has_no_token(self):
        import urllib.error
        token = "t" * 40
        error = urllib.error.HTTPError("https://x", 401, "no", {}, None)
        with mock.patch.object(script, "fetch", side_effect=error):
            code, out, err = self.run_main({"OPS_SUMMARY_URL": "https://api.example.com", "OPS_SUMMARY_TOKEN": token})
        self.assertEqual(code, 2)
        self.assertIn("rejected", err)
        self.assertNotIn(token, out + err)


if __name__ == "__main__":
    unittest.main()
