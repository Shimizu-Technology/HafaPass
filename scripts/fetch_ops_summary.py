#!/usr/bin/env python3
"""Print HåfaPass's daily sales and health summary as Markdown.

For the morning brief. Read-only; it only does one GET.

  OPS_SUMMARY_URL    e.g. https://hafapass-api.onrender.com  (no trailing path)
  OPS_SUMMARY_TOKEN  the bearer token Leon created (or OPS_SUMMARY_TOKEN_FILE,
                     a file holding it). Never printed, never put on a command line.

  fetch_ops_summary.py [--date YYYY-MM-DD|today] [--json]

Exit codes: 0 ok, 1 summary says something needs attention only with --strict,
2 setup or request problem (message on stderr, never the token).
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def money(cents):
    cents = int(cents or 0)
    sign = "-" if cents < 0 else ""
    return f"{sign}${abs(cents) / 100:,.2f}"


LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1")


class UnsafeUrl(ValueError):
    """The configured URL could expose the bearer token."""


def validate_base_url(base_url):
    """Return the normalized base URL, or raise UnsafeUrl.

    https only, with a host and no credentials, query or fragment. Plain http is
    accepted only for an explicit local development host, never a lookalike
    (http://localhost.evil.example is refused).
    """
    try:
        parsed = urllib.parse.urlsplit(base_url)
        host = parsed.hostname
        parsed.port  # noqa: B018 - raises ValueError on a malformed port
    except ValueError as error:
        raise UnsafeUrl("OPS_SUMMARY_URL is not a valid URL.") from error
    if parsed.scheme not in ("https", "http") or not host:
        raise UnsafeUrl("OPS_SUMMARY_URL must be an https:// URL.")
    if parsed.scheme == "http" and host not in LOCAL_HOSTS:
        raise UnsafeUrl("OPS_SUMMARY_URL must be https:// so the token is never sent in the clear (http is only for localhost).")
    if parsed.username is not None or parsed.password is not None:
        raise UnsafeUrl("OPS_SUMMARY_URL must not contain a username or password.")
    if parsed.query or parsed.fragment:
        raise UnsafeUrl("OPS_SUMMARY_URL must not contain a query or fragment.")
    return base_url.rstrip("/")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: the bearer token must only go to the configured host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)


def build_opener():
    return urllib.request.build_opener(NoRedirect)


def fetch(base_url, token, date=None, timeout=20, opener=None):
    url = validate_base_url(base_url) + "/api/v1/ops/summary"
    if date:
        url += "?" + urllib.parse.urlencode({"date": date})
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
    with (opener or build_opener()).open(request, timeout=timeout) as response:
        return json.load(response)


def attention(summary):
    """Plain-language problems found in the summary; empty means all clear."""
    health = summary.get("health", {})
    problems = []
    if health.get("readiness") != "ready":
        problems.append(f"Readiness is {health.get('readiness', 'unknown')}")
    hooks = health.get("stripe_webhooks", {})
    if hooks.get("silent"):
        problems.append("Stripe webhooks look silent while payments are being made")
    if hooks.get("failing"):
        problems.append(f"Stripe webhooks are failing ({hooks.get('failed_in_window', 0)} recent)")
    if hooks.get("signature_failing"):
        problems.append("Stripe is being rejected: signature verification fails (check the webhook signing secret)")
    for name, count in (health.get("operational_signals") or {}).items():
        if count and name not in ("stripe_webhook_failures", "stripe_webhooks_silent", "stripe_webhook_signature_failures"):
            problems.append(f"{name.replace('_', ' ')}: {count}")
    queue = health.get("job_queue", {})
    if queue.get("available") and queue.get("oldest_ready_age_seconds", 0) > 300:
        problems.append(f"Oldest waiting job is {queue['oldest_ready_age_seconds'] // 60} minutes old")
    return problems


def render(summary):
    sales = summary["sales"]
    health = summary["health"]
    hooks = health.get("stripe_webhooks", {})
    window = summary.get("window", {})
    lines = [f"# HåfaPass daily summary, {summary['guam_date']} (Guam)" + (" so far" if window.get("partial") else ""), ""]

    problems = attention(summary)
    lines.append("## Needs attention" if problems else "## All clear")
    lines += [f"- {problem}" for problem in problems] or ["- Nothing needs you."]
    lines.append("")

    lines += ["## Sales",
              f"- Orders: {sales['orders']}, tickets: {sales['tickets']}",
              f"- Gross: {money(sales['gross_cents'])} "
              f"(online {money(sales['online']['gross_cents'])} in {sales['online']['orders']} orders, "
              f"door cash {money(sales['door_cash']['gross_cents'])} in {sales['door_cash']['orders']})",
              f"- Refunds: {money(sales['refund_cents'])} ({sales.get('refund_count', 0)})",
              "- Fees: " + (", ".join(f"{kind} {money(cents)}" for kind, cents in sales["fees_cents"].items() if cents) or "none"),
              ""]
    if summary["events"]:
        lines += ["## By event"]
        for event in summary["events"]:
            lines.append(f"- {event['title']}: {event['orders']} orders, {event['tickets']} tickets, {money(event['gross_cents'])} gross, "
                         f"{money(event['refund_cents'])} refunded (door cash {money(event['door_cash_gross_cents'])})")
        lines.append("")
    if summary["on_sale"]:
        lines += ["## Capacity left (on sale now)"]
        for event in summary["on_sale"]:
            left = "no cap" if event["capacity_remaining"] is None else f"{event['capacity_remaining']} of {event['max_capacity']} left"
            types = ", ".join(f"{t['name']} {t['remaining']}" for t in event["ticket_types"])
            lines.append(f"- {event['title']}: {left}" + (f" ({types})" if types else ""))
        lines.append("")

    queue = health.get("job_queue", {})
    lines += ["## Health",
              f"- Readiness: {health['readiness']}",
              f"- Stripe webhooks: last received {hooks.get('last_receipt_at') or 'never'}, "
              f"{hooks.get('receipts_last_hour', 0)} in the last hour, {hooks.get('failed_total', 0)} failed receipts standing",
              (f"- Job queue: {queue['ready']} waiting, {queue['claimed']} running, {queue['failed']} failed" if queue.get("available")
               else "- Job queue: not available"),
              "- Errors: see the Sentry app; this summary only counts operational signals "
              + ", ".join(f"{k.replace('_', ' ')} {v}" for k, v in (health.get("operational_signals") or {}).items()),
              "", f"_Generated {summary['generated_at']}, release {(summary.get('revision') or 'unknown')[:8]}._"]
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--date", help="YYYY-MM-DD (Guam) or 'today'; default is yesterday")
    parser.add_argument("--json", action="store_true", help="print the raw JSON instead of Markdown")
    parser.add_argument("--strict", action="store_true", help="exit 1 when something needs attention")
    args = parser.parse_args(argv)

    base_url = os.environ.get("OPS_SUMMARY_URL", "").strip()
    token = os.environ.get("OPS_SUMMARY_TOKEN", "").strip()
    token_file = os.environ.get("OPS_SUMMARY_TOKEN_FILE", "").strip()
    if not token and token_file:
        try:
            token = open(token_file, encoding="utf-8").read().strip()
        except OSError as error:
            print(f"Cannot read OPS_SUMMARY_TOKEN_FILE: {error.strerror}", file=sys.stderr)
            return 2
    if not base_url or not token:
        print("Set OPS_SUMMARY_URL and OPS_SUMMARY_TOKEN (or OPS_SUMMARY_TOKEN_FILE).", file=sys.stderr)
        return 2
    try:
        validate_base_url(base_url)
    except UnsafeUrl as error:
        print(str(error), file=sys.stderr)
        return 2

    try:
        summary = fetch(base_url, token, args.date)
    except urllib.error.HTTPError as error:
        if 300 <= error.code < 400:
            print("Summary request failed: the server tried to redirect, which is refused so the token is not forwarded. "
                  "Check OPS_SUMMARY_URL.", file=sys.stderr)
            return 2
        reason = {401: "the token was rejected", 404: "the endpoint is off (no OPS_SUMMARY_TOKEN on the server)",
                  422: "the date was not accepted", 429: "rate limited, try again in a minute"}.get(error.code, f"HTTP {error.code}")
        print(f"Summary request failed: {reason}.", file=sys.stderr)
        return 2
    except UnsafeUrl as error:
        print(str(error), file=sys.stderr)
        return 2
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        print(f"Summary request failed: {type(error).__name__}.", file=sys.stderr)
        return 2

    print(json.dumps(summary, indent=2) if args.json else render(summary))
    return 1 if args.strict and attention(summary) else 0


if __name__ == "__main__":
    sys.exit(main())
