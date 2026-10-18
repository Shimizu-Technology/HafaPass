# Recovering an email with an unknown provider acknowledgement

New Resend deliveries persist the exact HTTP JSON body and its SHA-256 digest in the same transaction as the payload, transport context, first-attempt marker, and unknown outcome. Retries send those stored bytes through the Resend SDK. JSONB field order and current JSON/HTML encoding settings cannot change the request body after that transaction.

An attempted legacy delivery with no stored wire body fails closed. `MessageDeliveryJob` enforces the replay fence before committing an attempt. Direct calls with a delivery require a clean, committed active attempt; a fresh direct delivery must go through that job. Real transport without a journal is blocked. Old SendTicketEmailJob and SendOrderConfirmationJob entries delegate only an existing matching delivery to the canonical job; missing journals fail closed. Do not regenerate HTML or access links, replace the idempotency key, rotate the provider context, cancel the unknown request, or assign a provider message ID manually.

The explicit legacy helper supports only `hafapass_6b_resend_v1`, the request builder in commit `6b858afbee6c41bb186acb2b6ec721a32ea56b0f` with Resend 1.0.0 and JSON 3.0.2. This profile orders fields as `from`, `to`, `subject`, `html`, optional `reply_to`, and `tags`; each tag orders `name` before `value`. It allows exactly one category tag and the documented email template categories. The original SDK invoked Rails' Hash#to_json encoder, which escaped `<`, `>`, `&`, U+2028 and U+2029. The helper pins those exact escapes after generating JSON from frozen values, independent of current Rails encoding settings. Full-Rails SDK probes verify the historical bytes; loading ActiveRecord alone does not reproduce that encoder. Extra fields, other encoders, and other profiles require separate reconciliation.

Before invoking the helper, an authorized operator must independently verify the original wire bytes and SHA-256 against the original provider request/key/account/endpoint. When replay is used as that verification, confirm the original cache remains active and the first attempt is within the application's 23-hour safety fence. Use only the one known, source-verified candidate. A successful replay must return the original independently verified message ID. If that candidate is rejected or identity differs, stop and retain uncertainty. Do not iterate through field-order or encoding guesses.

Keep the provider proof and exact wire bytes in a private mode-0600 file: the body can contain an attendee email and a bearer access link. Never commit or print it. Then invoke the helper in the authorized application environment:

```ruby
delivery = MessageDelivery.find(delivery_id)
MessageWirePayload.hydrate_legacy!(
  delivery,
  profile: "hafapass_6b_resend_v1",
  verified_wire_body: File.binread(private_verified_wire_path),
  verified_wire_digest: independently_verified_wire_sha256
)
```

The helper locks and reloads the delivery, verifies the original transport context and logical payload digest, rejects active sends and expired replay windows, and checks the verified bytes against the exact allowlisted schema/encoder. It persists only the wire body and digest. The outcome stays unknown, with the original recipient, idempotency key, context and first-attempt time. A model immutability guard and database digest constraint protect the prepared body.

After hydration, enqueue `MessageDeliveryJob` for that existing delivery. The actual worker must receive and record the original SDK acknowledgement, then reconcile signed provider receipts through the existing processor. Confirm one provider message and the expected receipt association. This is recovery evidence for that delivery; it does not approve production email or payments.
