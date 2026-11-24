"""Regression tests for scripts/rush_test (offline: no network, no k6, no database)."""
import importlib.util
import os
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUSH = ROOT / "scripts" / "rush_test"

spec = importlib.util.spec_from_file_location("collect_results", RUSH / "collect_results.py")
collect_results = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collect_results)


def run_preflight(env):
    clean = {key: value for key, value in os.environ.items() if not key.startswith(("HAFAPASS_", "BASE_URL"))}
    clean.update(env)
    return subprocess.run(["bash", str(RUSH / "preflight.sh")], env=clean, capture_output=True, text=True, timeout=30)


class PreflightRefusals(unittest.TestCase):
    def test_requires_explicit_target(self):
        result = run_preflight({})
        self.assertEqual(result.returncode, 2)
        self.assertIn("HAFAPASS_RUSH_TARGET is not set", result.stderr)

    def test_refuses_production_hosts_before_any_request(self):
        for host in ("hafapass-api.onrender.com", "hafapass.shimizu-technology.com", "api.hafapass.com", "hafapass.netlify.app"):
            with self.subTest(host=host):
                result = run_preflight({"HAFAPASS_RUSH_TARGET": host})
                self.assertEqual(result.returncode, 2)
                self.assertIn("production host", result.stderr)

    def test_refuses_extra_production_host(self):
        result = run_preflight({"HAFAPASS_RUSH_TARGET": "api.example.org", "HAFAPASS_PRODUCTION_HOSTS": "x.test, API.example.org"})
        self.assertEqual(result.returncode, 2)

    def test_target_must_match_base_url(self):
        result = run_preflight({"HAFAPASS_RUSH_TARGET": "rush-copy.onrender.com", "BASE_URL": "https://other-copy.onrender.com"})
        self.assertEqual(result.returncode, 2)
        self.assertIn("does not match", result.stderr)

    def test_target_must_be_a_bare_host(self):
        result = run_preflight({"HAFAPASS_RUSH_TARGET": "https://rush-copy.onrender.com"})
        self.assertEqual(result.returncode, 2)


class CollectResults(unittest.TestCase):
    summary = {
        "scenario": "paid_holds", "profile": "burst",
        "counts": {"free_order_success": 0, "free_order_clean_422": 0, "paid_hold_success": 200, "paid_hold_clean_422": 40,
                   "unexpected_422": 0, "payment_resume_success": 0, "throttled_429": 0, "server_errors_5xx": 0},
        "latencies_ms": {"events_index": None, "event_show": None, "free_order": None, "payment_resume": None,
                         "paid_hold": {"p50_ms": 400.0, "p95_ms": 1400.0, "p99_ms": 1600.0, "max_ms": 1700.0}},
    }

    def statuses(self, rows):
        return {item["name"]: item["status"] for item in rows}

    def test_meets_232_targets(self):
        rows = collect_results.evaluate(self.summary)
        self.assertEqual(collect_results.overall(rows), "PASS")
        self.assertEqual(self.statuses(rows)["Paid order (hold) p50 / p95 / p99 (ms)"], "PASS")

    def test_misses_order_target(self):
        slow = {**self.summary, "latencies_ms": {**self.summary["latencies_ms"], "paid_hold": {"p50_ms": 900.0, "p95_ms": 1501.0, "p99_ms": 2000.0, "max_ms": 2100.0}}}
        self.assertEqual(collect_results.overall(collect_results.evaluate(slow)), "FAIL")

    def test_any_throttle_or_server_error_fails(self):
        for key in ("throttled_429", "server_errors_5xx", "unexpected_422"):
            with self.subTest(key=key):
                bad = {**self.summary, "counts": {**self.summary["counts"], key: 1}}
                self.assertEqual(collect_results.overall(collect_results.evaluate(bad)), "FAIL")

    def test_listing_target_applies_when_a_listing_was_measured(self):
        with_listing = {**self.summary, "latencies_ms": {**self.summary["latencies_ms"], "events_index": {"p50_ms": 100.0, "p95_ms": 301.0, "p99_ms": 400.0, "max_ms": 450.0}}}
        self.assertEqual(self.statuses(collect_results.evaluate(with_listing))["Listing p50 / p95 / p99 (ms)"], "FAIL")

    def test_failed_consistency_check_fails_the_run(self):
        consistency = {"checks": [{"name": "oversell", "value": 1, "pass": False}], "tables": {}}
        self.assertEqual(collect_results.overall(collect_results.evaluate(self.summary, consistency)), "FAIL")

    def test_sell_out_time_reports_created_span_when_nothing_completed(self):
        consistency = {"checks": [], "tables": {"event_timing": [
            {"event_id": 9, "orders_total": 200, "orders_completed": 0, "first_order_to_last_completion_seconds": None, "first_to_last_order_created_seconds": "7.4"}]}}
        rows = collect_results.evaluate(None, consistency)
        self.assertIn("no completed orders; 7.4 s first to last order created", rows[0]["value"])
        self.assertEqual(rows[0]["status"], "INFO")

    def test_no_data(self):
        self.assertEqual(collect_results.overall(collect_results.evaluate()), "NO DATA")

    def test_renders_markdown(self):
        text = collect_results.render(collect_results.evaluate(self.summary), {"label": "x", "started_utc": "a", "ended_utc": "b", "k6_exit_status": 0}, self.summary)
        self.assertIn("| Criterion | Measured | Target | Verdict |", text)
        self.assertIn("Automated verdict: PASS", text)


@unittest.skipUnless(shutil.which("node"), "node not installed")
class K6ScriptSelfCheck(unittest.TestCase):
    def test_burst_ramp_and_guards(self):
        result = subprocess.run(["node", str(RUSH / "check_k6_script.mjs")], capture_output=True, text=True, timeout=120,
                                env={**os.environ, "K6_BIN": os.environ.get("K6_BIN", "k6")})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
