# frozen_string_literal: true

# Provider stubs for the two-process rehearsal (rehearse_two_process.sh).
# Loaded by both the 7bcd97c2 app and this release's app, each in its own
# `bin/rails runner` process against one task-owned database. No network.
#
# Stripe is simulated by one JSON ledger file shared by both processes, so a
# refund one process POSTs is what the other finds by its key, as at Stripe.
# Every provider call is appended to calls.jsonl with the process's role.
# A pause point blocks the process inside a stubbed call until the driver
# releases it: REHEARSAL_PAUSE=<label> writes <label>.reached (with its
# database backend pid), then waits for <label>.release.
require "json"
require "ostruct"
require "fileutils"
require "digest"

module Rehearsal
  DIR = ENV.fetch("REHEARSAL_DIR")
  ROLE = ENV.fetch("REHEARSAL_ROLE")
  LEDGER = File.join(DIR, "stripe_ledger.json")

  module_function

  def log!(kind, **data)
    File.open(File.join(DIR, "calls.jsonl"), "a") do |file|
      file.flock(File::LOCK_EX)
      file.puts(JSON.generate({ role: ROLE, kind: kind, at: Time.now.utc.iso8601(6) }.merge(data)))
    end
  end

  def outcome!(step, **data)
    File.open(File.join(DIR, "outcomes.jsonl"), "a") do |file|
      file.flock(File::LOCK_EX)
      file.puts(JSON.generate({ role: ROLE, step: step }.merge(data)))
    end
  end

  def pause(label)
    return unless ENV["REHEARSAL_PAUSE"].to_s.split(",").include?(label)

    mark(label)
    deadline = Time.now + 120
    until File.exist?(File.join(DIR, "#{label}.release"))
      raise "pause #{label} was never released" if Time.now > deadline

      sleep 0.05
    end
  end

  # Writes <label>.reached holding this process's database backend pid
  # (atomically, so the driver never reads it half written). The driver
  # proves a wait with pg_blocking_pids on these pids (CodeRabbit
  # 4705527122), not with a timer.
  def mark(label)
    pid = defined?(ActiveRecord::Base) ? ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()") : ""
    path = File.join(DIR, "#{label}.reached")
    File.write("#{path}.tmp", pid.to_s)
    File.rename("#{path}.tmp", path)
  end

  def ledger
    File.open(LEDGER, File::RDWR | File::CREAT) do |file|
      file.flock(File::LOCK_EX)
      text = file.read
      data = text.empty? ? {} : JSON.parse(text)
      result = yield data
      file.rewind
      file.truncate(0)
      file.write(JSON.generate(data))
      result
    end
  end

  def refund_object(entry)
    OpenStruct.new(id: entry["id"], status: entry["status"], amount: entry["amount"], currency: entry["currency"],
      payment_intent: entry["payment_intent"], created: entry["created"],
      metadata: { "hafapass_refund_key" => entry["key"] }.compact)
  end
end

StripeService.singleton_class.prepend(Module.new do
  def refund_payment(intent_id, amount_cents:, idempotency_key:, **)
    Rehearsal.pause("post")
    entry = Rehearsal.ledger do |data|
      # Stripe returns the first result for a repeated idempotency key.
      data[idempotency_key] ||= { "id" => "re_reh_#{Digest::SHA256.hexdigest(idempotency_key)[0, 10]}", "status" => "succeeded",
        "amount" => amount_cents, "currency" => "usd", "payment_intent" => intent_id, "key" => idempotency_key,
        "created" => Time.now.to_i }
    end
    Rehearsal.log!("refund_post", intent: intent_id, amount_cents: amount_cents, key: idempotency_key, provider_refund_id: entry["id"])
    Rehearsal.refund_object(entry)
  end

  def find_refund(intent_id, idempotency_key:, **options)
    Rehearsal.pause("lookup")
    entry = Rehearsal.ledger { |data| data[idempotency_key] }
    entry = nil if entry && entry["payment_intent"] != intent_id
    Rehearsal.log!("refund_lookup", intent: intent_id, key: idempotency_key, found: entry&.fetch("id"),
      amount_date_fallback: options.key?(:expected_amount_cents))
    entry && Rehearsal.refund_object(entry)
  end

  def list_refunds(payment:, **)
    entries = Rehearsal.ledger { |data| data.values.select { |entry| entry["payment_intent"] == payment.provider_payment_id } }
    Rehearsal.log!("refund_list", intent: payment.provider_payment_id, count: entries.length)
    entries.map { |entry| Rehearsal.refund_object(entry) }
  end

  def verify_payment_context!(*) = nil
  def card_only_intent?(*) = true
  def payment_enabled?(*) = true

  def create_payment_intent(*, **)
    OpenStruct.new(id: "pi_reh_#{SecureRandom.hex(4)}", client_secret: "secret", allowed_payment_method_types: ["card"],
      payment_method_types: ["card"])
  end

  def retrieve_fee_payment_intent(*) = raise(StripeService::PaymentError, "fee lookup not rehearsed")
end)

PayoutGateway.singleton_class.prepend(Module.new do
  def submit(payout)
    Rehearsal.pause("payout_gateway")
    Rehearsal.log!("payout_submit", payout_id: payout.id, amount_cents: payout.amount_cents)
    PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
  end
end)

EmailService.singleton_class.prepend(Module.new do
  def send_refund_notification_async(order, **)
    Rehearsal.log!("refund_email", order_id: order.id)
  end

  def send_order_confirmation_async(*, **) = nil
end)

# Boundary-fix pause points (both releases have these methods). "capture":
# inside a capture's open transaction, after the payment update, before its
# commit (OrderLifecycle#mark_payment_succeeded! requests the fee lookup
# there). "submission_audit": inside a payout submission's transaction, right
# after its authorization audit row. "reversal_audit": see below.
StripeProcessingFees.singleton_class.prepend(Module.new do
  def request!(payment, **options)
    result = super
    Rehearsal.pause("capture") if Payment.connection.transaction_open?
    result
  end
end)

AuditLogger.singleton_class.prepend(Module.new do
  def record!(**attributes)
    result = super
    Rehearsal.pause("submission_audit") if attributes[:action] == "payout.submission_requested"
    # "reversal_audit": inside a payout reversal's transaction, after its
    # reconciled audit row and before its commit (A2 recheck finding 1).
    if attributes[:action] == "payout.reconciled" && attributes[:after_data].to_h.stringify_keys["status"] == "reversed"
      Rehearsal.pause("reversal_audit")
    end
    result
  end
end)
