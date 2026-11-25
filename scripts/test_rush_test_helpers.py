"""Regression tests for scripts/rush_test (offline: no network, no k6, no database)."""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUSH = ROOT / "scripts" / "rush_test"

spec = importlib.util.spec_from_file_location("collect_results", RUSH / "collect_results.py")
collect_results = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collect_results)


def write_stub(directory, name, body):
    path = Path(directory) / name
    path.write_text("#!/usr/bin/env bash\n" + body)
    path.chmod(0o755)
    return path


def run_preflight(env, path_prefix=None):
    clean = {key: value for key, value in os.environ.items() if not key.startswith(("HAFAPASS_", "BASE_URL"))}
    clean.update(env)
    if path_prefix:
        clean["PATH"] = f"{path_prefix}:{clean['PATH']}"
    return subprocess.run(["bash", str(RUSH / "preflight.sh")], env=clean, capture_output=True, text=True, timeout=30)


class PreflightRefusals(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.calls = Path(self.tmp.name) / "curl-calls.txt"
        # A recording curl placed first on PATH: a refusal must happen before any request is made.
        write_stub(self.tmp.name, "curl", f'echo "$@" >> "{self.calls}"\nexit 7\n')

    def refuse(self, env):
        result = run_preflight(env, self.tmp.name)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse(self.calls.exists(), f"curl was called before the refusal: {self.calls.read_text() if self.calls.exists() else ''}")
        return result

    def test_requires_explicit_target(self):
        self.assertIn("HAFAPASS_RUSH_TARGET is not set", self.refuse({}).stderr)

    def test_refuses_production_hosts_before_any_request(self):
        for host in ("hafapass-api.onrender.com", "hafapass.shimizu-technology.com", "api.hafapass.com", "hafapass.netlify.app"):
            with self.subTest(host=host):
                self.assertIn("production host", self.refuse({"HAFAPASS_RUSH_TARGET": host}).stderr)

    def test_refuses_extra_production_host(self):
        self.refuse({"HAFAPASS_RUSH_TARGET": "api.example.org", "HAFAPASS_PRODUCTION_HOSTS": "x.test, API.example.org"})

    def test_target_must_match_base_url(self):
        result = self.refuse({"HAFAPASS_RUSH_TARGET": "rush-copy.onrender.com", "BASE_URL": "https://other-copy.onrender.com"})
        self.assertIn("does not match", result.stderr)

    def test_target_must_be_a_bare_host(self):
        self.refuse({"HAFAPASS_RUSH_TARGET": "https://rush-copy.onrender.com"})

    def test_the_recording_stub_does_see_a_real_request(self):
        # Guards the guard: with an allowed target preflight does call curl, so an empty record above means something.
        result = run_preflight({"HAFAPASS_RUSH_TARGET": "rush-copy.onrender.com"}, self.tmp.name)
        self.assertNotEqual(result.returncode, 2)
        self.assertTrue(self.calls.exists())


class RunK6StaleSummary(unittest.TestCase):
    """run_k6.sh must delete the previous summary, so a failed run cannot be judged on old numbers."""

    def test_stale_summary_is_removed_and_failure_recorded(self):
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "bin"
            bin_dir.mkdir()
            write_stub(bin_dir, "curl", r'''
case "$*" in
  *"-w"*) printf 200; exit 0 ;;
  *"/api/v1/health"*) echo '{"status":"ok","revision":"0123456789abcdef0123456789abcdef01234567"}' ;;
  *"/api/v1/config"*) echo '{"payment_mode":"simulate","environment":"staging"}' ;;
  *) echo '{}' ;;
esac
''')
            write_stub(bin_dir, "fake-k6", 'if [ "$1" = "version" ]; then echo "k6 fake"; exit 0; fi\nexit 99\n')
            results = Path(tmp) / "results"
            results.mkdir()
            stale = results / "r1.summary.json"
            stale.write_text('{"counts": {"paid_hold_success": 200}, "thresholds_passed": true}')
            env = {key: value for key, value in os.environ.items() if not key.startswith(("HAFAPASS_", "BASE_URL"))}
            env.update({"PATH": f"{bin_dir}:{env['PATH']}", "K6_BIN": str(bin_dir / "fake-k6"), "HAFAPASS_RUSH_TARGET": "rush-copy.onrender.com",
                        "ISOLATED_LOAD_TARGET_ACK": "I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT",
                        "RESULTS_DIR": str(results), "RUN_LABEL": "r1"})
            result = subprocess.run(["bash", str(RUSH / "run_k6.sh")], env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 99, result.stdout + result.stderr)
            self.assertFalse(stale.exists(), "the stale summary survived a run that wrote none")
            times = json.loads((results / "r1.times.json").read_text())
            self.assertEqual(times["k6_exit_status"], 99)
            # And the collector refuses to pass that run.
            outcome = subprocess.run([sys.executable, str(RUSH / "collect_results.py"), "--k6", str(stale), "--times", str(results / "r1.times.json")],
                                     capture_output=True, text=True, timeout=30)
            self.assertEqual(outcome.returncode, 1, outcome.stdout)
            self.assertIn("Automated verdict: FAIL", outcome.stdout)
            self.assertIn("k6 summary file", outcome.stdout)


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

    def test_nonzero_k6_exit_status_fails_even_with_clean_counts(self):
        rows = collect_results.evaluate(self.summary, times={"k6_exit_status": 99})
        self.assertEqual(collect_results.overall(rows), "FAIL")
        self.assertEqual(self.statuses(rows)["k6 exit status"], "FAIL")

    def test_zero_exit_status_is_a_pass_row(self):
        rows = collect_results.evaluate(self.summary, times={"k6_exit_status": 0})
        self.assertEqual(self.statuses(rows)["k6 exit status"], "PASS")
        self.assertEqual(collect_results.overall(rows), "PASS")

    def test_failed_k6_thresholds_fail(self):
        rows = collect_results.evaluate({**self.summary, "thresholds_passed": False})
        self.assertEqual(self.statuses(rows)["k6 thresholds passed (its own pass/fail)"], "FAIL")
        self.assertEqual(collect_results.overall(rows), "FAIL")

    def test_no_orders_ran_fails(self):
        empty = {**self.summary, "counts": {**self.summary["counts"], "paid_hold_success": 0, "paid_hold_clean_422": 0}}
        rows = collect_results.evaluate(empty)
        self.assertEqual(self.statuses(rows)["Orders accepted (201)"], "FAIL")
        self.assertEqual(collect_results.overall(rows), "FAIL")

    def test_dropped_iterations_fail_a_ramp(self):
        rows = collect_results.evaluate({**self.summary, "counts": {**self.summary["counts"], "dropped_iterations": 3}})
        self.assertEqual(self.statuses(rows)["Dropped iterations (ramp ran out of VUs)"], "FAIL")
        ok = collect_results.evaluate({**self.summary, "counts": {**self.summary["counts"], "dropped_iterations": 0}})
        self.assertEqual(collect_results.overall(ok), "PASS")

    def test_missing_summary_file_fails_and_main_exits_nonzero(self):
        rows = collect_results.evaluate(None, k6_missing="rush-results/x.summary.json")
        self.assertEqual(collect_results.overall(rows), "FAIL")
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(collect_results.main(["--k6", str(Path(tmp) / "absent.json")]), 1)

    def test_main_exits_zero_on_a_clean_run(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            summary, times = Path(tmp) / "s.json", Path(tmp) / "t.json"
            summary.write_text(json.dumps({**self.summary, "thresholds_passed": True}))
            times.write_text(json.dumps({"label": "x", "started_utc": "a", "ended_utc": "b", "k6_exit_status": 0}))
            self.assertEqual(collect_results.main(["--k6", str(summary), "--times", str(times)]), 0)

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
