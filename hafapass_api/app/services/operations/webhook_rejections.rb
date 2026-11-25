# frozen_string_literal: true

module Operations
  # Counts provider webhooks rejected before a receipt is stored (no
  # WebhookEvent row exists for those), so a wrong signing secret is visible.
  # Only a count per five-minute bucket is kept.
  #
  # A rejected delivery proves nothing about who sent it or in which Stripe
  # mode: the signature failed, so the payload (including its livemode flag)
  # can't be trusted, and anyone on the internet can post to the public URL.
  # So these counts are "unverified rejected deliveries", never evidence on
  # their own (see Operations::StripeWebhookHealth).
  #
  # Reasons: invalid_signature (a Stripe-shaped signature header that failed
  # verification), secret_missing (a Stripe-shaped signature but no secret
  # configured), signature_missing (no signature, or a header that isn't
  # Stripe-shaped: internet noise, recorded but never alerted on).
  #
  # Write budget: counting happens in memory and is flushed to the database in
  # one statement at most every FLUSH_SECONDS per process (the first rejection
  # after a quiet spell writes at once; a trailing flush follows a burst). A
  # flood of junk therefore costs one small write per interval per process, no
  # matter how many requests arrive, and can't compete with real deliveries
  # for database capacity.
  module WebhookRejections
    BUCKET = 5.minutes
    ALERT_REASONS = %w[invalid_signature secret_missing].freeze
    REASONS = (ALERT_REASONS + %w[signature_missing]).freeze
    DEFAULT_FLUSH_SECONDS = 10
    MAX_PENDING_KEYS = 200
    STRIPE_SIGNATURE_SHAPE = /\At=\d{1,12},\s*v1=[0-9a-f]{16,}/i

    @mutex = Mutex.new
    @pending = Hash.new(0)
    @last_flush = nil
    @timer_scheduled = false

    module_function

    # A header that looks like Stripe's. Shape proves nothing about origin (it
    # can be forged), only that the sender tried to be Stripe.
    def stripe_shaped?(signature)
      signature.to_s.match?(STRIPE_SIGNATURE_SHAPE)
    end

    # Never raises: counting must not change the response Stripe sees.
    def record!(provider:, reason:, at: Time.current)
      return unless REASONS.include?(reason)

      key = [provider, reason, Time.zone.at((at.to_i / BUCKET.to_i) * BUCKET.to_i)]
      flush_now, delay = @mutex.synchronize do
        @pending[key] += 1 if @pending.key?(key) || @pending.size < MAX_PENDING_KEYS
        now = monotonic_now
        elapsed = @last_flush && (now - @last_flush)
        if elapsed.nil? || elapsed >= flush_seconds
          # Claim the slot here, inside the lock, so concurrent requests can't
          # each decide the interval has passed and all write.
          @last_flush = now
          [true, nil]
        elsif !@timer_scheduled
          @timer_scheduled = true
          [false, flush_seconds - elapsed]
        else
          [false, nil]
        end
      end
      flush! if flush_now
      schedule_trailing_flush(delay) if delay
    rescue StandardError => e
      Rails.logger.error({ event: "webhook_rejection_count_failed", error_class: e.class.name }.to_json)
    end

    # One INSERT ... ON CONFLICT for everything pending. A failed write puts the
    # counts back (bounded) so a database blip doesn't lose them. Does nothing
    # while writes are blocked (the read-only ops summary): the counts stay
    # pending, and #count adds them in. The flush clock only advances on a
    # successful write.
    def flush!
      return if ActiveRecord::Base.current_preventing_writes

      batch = @mutex.synchronize { @pending.dup.tap { @pending.clear } }
      return if batch.empty?

      now = Time.current
      rows = batch.map do |(provider, reason, bucket), count|
        { provider: provider, reason: reason, bucket_started_at: bucket, count: count, created_at: now, updated_at: now }
      end
      WebhookRejectionCount.upsert_all(rows, unique_by: :index_webhook_rejection_counts_on_bucket,
        on_duplicate: Arel.sql("count = webhook_rejection_counts.count + EXCLUDED.count, updated_at = EXCLUDED.updated_at"))
      @mutex.synchronize { @last_flush = monotonic_now }
    rescue StandardError => e
      @mutex.synchronize do
        batch&.each { |key, count| @pending[key] += count if @pending.key?(key) || @pending.size < MAX_PENDING_KEYS }
      end
      Rails.logger.error({ event: "webhook_rejection_flush_failed", error_class: e.class.name }.to_json)
    end

    # Persisted counts plus this process's pending ones, so a read never
    # under-reports. Flushes first when it may write; inside a read-only block
    # (the ops summary) it reads without writing.
    def count(provider:, since:, reasons: ALERT_REASONS)
      flush!
      from = since - BUCKET + 1.second
      persisted = WebhookRejectionCount.where(provider: provider, reason: reasons, bucket_started_at: from..).sum(:count)
      pending = @mutex.synchronize do
        @pending.sum { |(key_provider, reason, bucket), count| key_provider == provider && reasons.include?(reason) && bucket >= from ? count : 0 }
      end
      persisted + pending
    end

    # Specs: forget pending counts and the flush clock.
    def reset!
      @mutex.synchronize do
        @pending.clear
        @last_flush = nil
        @timer_scheduled = false
      end
    end

    def pending_count
      @mutex.synchronize { @pending.values.sum }
    end

    def flush_seconds
      value = Integer(ENV["HAFAPASS_WEBHOOK_REJECTION_FLUSH_SECONDS"].to_s.strip, 10, exception: false)
      value && value >= 0 ? value : DEFAULT_FLUSH_SECONDS
    end

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Flushes what a burst left behind once the interval passes, so counts don't
    # wait for the next rejection. Skipped in tests, which call flush!.
    def schedule_trailing_flush(delay)
      return if Rails.env.test?

      Thread.new do
        sleep(delay)
        @mutex.synchronize { @timer_scheduled = false }
        ActiveRecord::Base.connection_pool.with_connection { flush! }
      rescue StandardError => e
        Rails.logger.error({ event: "webhook_rejection_flush_failed", error_class: e.class.name }.to_json)
      end
    end
  end
end
