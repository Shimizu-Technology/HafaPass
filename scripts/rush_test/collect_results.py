#!/usr/bin/env python3
"""Turn the files a rush run leaves behind into the automated rows of RESULTS_TEMPLATE.md.

Inputs (all optional, pass what you have; every file is plain JSON written by this folder's tools):
  --k6          rush-results/<label>.summary.json   (k6 handleSummary output; a path that does not exist is a FAIL)
  --times       rush-results/<label>.times.json     (run_k6.sh start/end, UTC)
  --consistency consistency.json                    (script/rush_test/consistency_check.rb, RUSH_OUT=...)
  --sampler     pg_sampler.json                     (script/rush_test/pg_sampler.rb, RUSH_OUT=...)
  --rtt         neon_rtt.json                       (script/rush_test/neon_rtt.rb, RUSH_OUT=...)

Prints Markdown with a PASS/FAIL/INFO verdict per criterion. Targets are PR #232's:
order p95 <= 1500 ms, listing p95 <= 300 ms, no oversell, no 429/5xx/unexpected 422.
It reads files only; it never contacts anything.

  python3 scripts/rush_test/collect_results.py --k6 rush-results/paid-burst-1.summary.json \
      --times rush-results/paid-burst-1.times.json --consistency consistency.json > results-paid-burst-1.md
"""
import argparse
import json
import os
import sys

TARGETS = {"order_p95_ms": 1500, "listing_p95_ms": 300}


def load(path):
    if not path:
        return None
    with open(path) as handle:
        return json.load(handle)


def row(name, value, target, status):
    return {"name": name, "value": value, "target": target, "status": status}


def verdict(ok):
    return "PASS" if ok else "FAIL"


def latency(summary, key):
    block = (summary or {}).get("latencies_ms", {}).get(key)
    return block if block else None


def evaluate(k6=None, consistency=None, sampler=None, rtt=None, times=None, k6_missing=None):
    rows = []
    if k6_missing:
        rows.append(row("k6 summary file", f"missing: {k6_missing}", "present (run_k6.sh deletes the old one before each run)", "FAIL"))
    if times is not None and "k6_exit_status" in times:
        status = times["k6_exit_status"]
        rows.append(row("k6 exit status", status, "0", verdict(status == 0)))
    if k6:
        if "thresholds_passed" in k6:
            rows.append(row("k6 thresholds passed (its own pass/fail)", k6["thresholds_passed"], "true", verdict(k6["thresholds_passed"] is True)))
        if "dropped_iterations" in k6.get("counts", {}):
            dropped = k6["counts"]["dropped_iterations"]
            rows.append(row("Dropped iterations (ramp ran out of VUs)", dropped, "0", verdict(dropped == 0)))
        counts = k6.get("counts", {})
        sold = counts.get("free_order_success", 0) + counts.get("paid_hold_success", 0)
        refused = counts.get("free_order_clean_422", 0) + counts.get("paid_hold_clean_422", 0)
        rows.append(row("Orders accepted (201)", sold, "> 0", verdict(sold > 0)))
        rows.append(row("Clean sold-out refusals (422)", refused, "info", "INFO"))
        rows.append(row("Unexpected 422", counts.get("unexpected_422", 0), "0", verdict(counts.get("unexpected_422", 0) == 0)))
        rows.append(row("429 throttled", counts.get("throttled_429", 0), "0", verdict(counts.get("throttled_429", 0) == 0)))
        rows.append(row("5xx / network errors", counts.get("server_errors_5xx", 0), "0", verdict(counts.get("server_errors_5xx", 0) == 0)))
        for key, label in (("free_order", "Free order"), ("paid_hold", "Paid order (hold)")):
            block = latency(k6, key)
            if block:
                rows.append(row(f"{label} p50 / p95 / p99 (ms)", f"{block['p50_ms']} / {block['p95_ms']} / {block['p99_ms']}",
                                f"p95 <= {TARGETS['order_p95_ms']}", verdict(block["p95_ms"] <= TARGETS["order_p95_ms"])))
        block = latency(k6, "events_index")
        if block:
            rows.append(row("Listing p50 / p95 / p99 (ms)", f"{block['p50_ms']} / {block['p95_ms']} / {block['p99_ms']}",
                            f"p95 <= {TARGETS['listing_p95_ms']}", verdict(block["p95_ms"] <= TARGETS["listing_p95_ms"])))
        for key, label in (("event_show", "Event page"), ("payment_resume", "payment_resume")):
            block = latency(k6, key)
            if block:
                rows.append(row(f"{label} p50 / p95 / p99 (ms)", f"{block['p50_ms']} / {block['p95_ms']} / {block['p99_ms']}", "info", "INFO"))
    if consistency:
        for check in consistency.get("checks", []):
            rows.append(row(check["name"], check["value"], "pass", verdict(check["pass"])))
        for timing in consistency.get("tables", {}).get("event_timing", []):
            seconds = timing.get("first_order_to_last_completion_seconds")
            created = timing.get("first_to_last_order_created_seconds")
            if timing.get("orders_total"):
                value = f"{seconds} s to last completion" if seconds is not None else "no completed orders"
                if created is not None:
                    value += f"; {created} s first to last order created"
                rows.append(row(f"Sell-out time, event {timing['event_id']} ({timing['orders_completed']} of {timing['orders_total']} completed)",
                                value, "info (compare with the RTT estimate)", "INFO"))
    if sampler:
        rows.append(row("Peak database sessions (pg_stat_activity)", sampler.get("peak_total_connections"), "below Neon max_connections", "INFO"))
        rows.append(row("Peak active queries", sampler.get("peak_active"), "info", "INFO"))
        rows.append(row("Peak lock waiters / share of busy samples", f"{sampler.get('peak_lock_waiters')} / {sampler.get('lock_wait_share_of_busy_samples')}",
                        "info (this is the event row lock)", "INFO"))
    if rtt:
        for endpoint in rtt.get("endpoints", []):
            select = endpoint["select_1_ms"]
            rows.append(row(f"Neon RTT {endpoint['label']}: p50 / p95 / p99 (ms)", f"{select['p50']} / {select['p95']} / {select['p99']}", "info", "INFO"))
        estimate = rtt.get("estimate")
        if estimate:
            rows.append(row("Estimated sell-out of 200 from RTT (s)", f"{estimate['sell_out_seconds_for_200_low']} - {estimate['sell_out_seconds_for_200_high']}",
                            "info (PR #232 estimated 8-18 s)", "INFO"))
    return rows


def overall(rows):
    statuses = [item["status"] for item in rows]
    if not statuses:
        return "NO DATA"
    return "FAIL" if "FAIL" in statuses else "PASS"


def render(rows, times=None, k6=None):
    lines = []
    if times or k6:
        label = (times or {}).get("label", "")
        lines.append(f"Run `{label}`: scenario `{(k6 or times or {}).get('scenario', '?')}`, profile `{(k6 or times or {}).get('profile', '?')}`"
                     + (f", {times['started_utc']} to {times['ended_utc']} (UTC), k6 exit status {times['k6_exit_status']}" if times else ""))
        lines.append("")
    lines += ["| Criterion | Measured | Target | Verdict |", "| --- | --- | --- | --- |"]
    for item in rows:
        lines.append(f"| {item['name']} | {item['value']} | {item['target']} | {item['status']} |")
    lines += ["", f"**Automated verdict: {overall(rows)}** (INFO rows do not decide it; the sheet's manual rows still need filling)."]
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for name in ("k6", "times", "consistency", "sampler", "rtt"):
        parser.add_argument(f"--{name}")
    args = parser.parse_args(argv)
    k6_missing = args.k6 if args.k6 and not os.path.exists(args.k6) else None
    k6, times = (None if k6_missing else load(args.k6)), load(args.times)
    rows = evaluate(k6, load(args.consistency), load(args.sampler), load(args.rtt), times=times, k6_missing=k6_missing)
    print(render(rows, times, k6))
    return 1 if overall(rows) == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main())
