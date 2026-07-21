# Gate F Buyer, Organizer, Accessibility, and Load Evidence

Status: application controls implemented; real candidate evidence pending.

Gate F prevents an event from being published, resumed, or sold in production until the exact Gate E candidate has independently approved proof of representative-user, device, accessibility, and load validation. It does not claim that CI used physical devices or that a qualified accessibility reviewer has signed off.

## What the application enforces

An administrator submits one append-only evidence snapshot. A different administrator must approve it. The approval is valid only while all of the following remain true:

- the linked Gate E approval is current and unrevoked;
- the material event/organizer/venue/pricing/inventory/seating digest still matches;
- the deployed `GIT_SHA` matches the tested application revision;
- the evidence window is effective and unexpired; and
- the Gate F approval has not been revoked.

Production publish/resume, public checkout, box office, and internal order creation fail closed when the approval is missing or stale. Ordinary sales counters do not change the event digest.

The admin event list uses only preloaded review records. It does not recompute event digests for every row; the exact digest is evaluated only when details are opened or a safety decision is made.

## Required evidence bundle

Store the bundle in approved restricted storage and record only its reference and SHA-256 in HafaPass. Never put credentials, buyer PII, raw identity documents, medical information, private phone numbers, or payment data in Git or screenshots.

The bundle must contain:

1. Device/version/tester records for physical iOS Safari, physical Android Chrome, and desktop Chrome. Desktop Safari, Firefox, and Edge must pass when available or have a specific availability exception.
2. Buyer journeys for guest and authenticated checkout, provider return/recovery, refund, transfer, wallet or the signed no-launch decision, reminder, waitlist, add-on, assigned seating or N/A, ticket presentation, low connectivity, and browser loss.
3. Organizer/staff journeys for role boundaries, lifecycle, finance, communications, seating or N/A, box office, support, and admin isolation.
4. Keyboard, focus/dialog, error/status, zoom/reflow, reduced-motion, accessible-seat discovery/purchase, and no-medical-proof checks.
5. Physical iOS VoiceOver, physical Android TalkBack, and one representative desktop screen-reader result, with tester and artifact references.
6. A named qualified accessibility reviewer, qualification reference, and signed approval artifact.
7. A load report containing scenario/tool/environment, expected and executed concurrency, request count, duration, p95 and its budget, error rate and its budget, peak/limit database connections, inventory and assigned-seat contention attempts, expected/observed expirations, hold reconciliation, and zero oversells/duplicate sales.
8. A severity-triaged issue register proving that all release blockers are resolved and no P0/P1 remains open.

HafaPass validates the internal consistency of these claims. Humans remain responsible for verifying that the referenced artifacts are genuine and representative.

## Safe load protocol

The repository includes `load_tests/gate_f_onsale.js` for k6. It intentionally refuses ordinary or paid events.

1. Deploy the exact candidate revision to an isolated production-like environment with production-sized web/worker/database/Redis configuration and monitoring.
2. Create a published general-admission event whose title starts with `[LOAD TEST]`, with a free ticket, no required registration/waiver fields, and at least `expected buyers × iterations per buyer` inventory. Do not reuse the selected real pilot event. The finite iteration count prevents an accidental unbounded stream of test orders.
3. If assigned seating will launch, create a separate `[LOAD TEST]` assigned-seating fixture with the representative layout, then pass its slug and one real `event_seat_id` as the contention target. The test intentionally sends simultaneous holds for that seat; one acceptance and safe `422` rejections are expected.
4. Capture application latency/error telemetry, database connection peaks, worker/queue behavior, hold expiry/reconciliation, final inventory, and the generated k6 JSON.
5. Reconcile every order/hold and prove database-level sold inventory never exceeded configured inventory. Delete the isolated environment or dispose of test data under the approved retention process.

Example:

```bash
ISOLATED_LOAD_TARGET_ACK=I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT \
BASE_URL=https://isolated-candidate.example.invalid \
EVENT_SLUG=load-test-pilot-onsale \
TICKET_TYPE_ID=123 \
EXPECTED_CONCURRENT_BUYERS=50 \
ITERATIONS_PER_BUYER=10 \
MAX_DURATION=5m \
CONTENTION_EVENT_SLUG=load-test-pilot-seating \
CONTENTION_EVENT_SEAT_ID=456 \
k6 run load_tests/gate_f_onsale.js
```

The script's default technical thresholds are at most 1% unexpected checkout failures and p95 at most 1,500 ms. The admin evidence also requires the observed result to meet the explicitly declared pilot budget, database connections to remain below the configured limit, expiration counts to reconcile, and oversell/duplicate-sale counts to equal zero. Change k6 thresholds only through reviewed source changes; do not loosen them at runtime to make a report pass.

## Decision procedure

1. QA lead verifies the bundle came from the exact `GIT_SHA`, Gate E approval, event digest, and isolated environment.
2. Submit the complete structured record in Admin → Events → Gate F.
3. A different administrator opens the same record, checks the restricted artifacts and issue register, then approves or rejects with a specific reason.
4. Revoke immediately after a material event/venue/provider change, a newly discovered release blocker, evidence integrity concern, or invalid accessibility/load assumption. Configuration and revision changes also invalidate automatically.

Gate F approval is necessary but not sufficient to launch. Gate G is enforced through [Gate G Physical Event-Day Rehearsal Evidence](GATE_G_EVENT_DAY_REHEARSAL_EVIDENCE.md); its real physical evidence is still pending. Gate H live-money proof and later launch/closeout gates remain separate.
