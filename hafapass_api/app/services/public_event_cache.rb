# frozen_string_literal: true

# Server-side cache for unauthenticated public event listing and detail JSON.
#
# Entries live in each process's bounded MemoryStore (config/environments/
# production.rb) for at most EventsController::PUBLIC_CACHE_TTL. Keys include a
# shared generation stored in PostgreSQL, so an inventory transition seen by one
# Puma worker invalidates the entries of every worker on their next read:
#
# - a checkout that takes the last unit of a ticket type, price tier, event
#   capacity or included pass night;
# - inventory coming back (a hold released or expired, a ticket cancelled or
#   refunded, a waitlist offer issued or ended);
# - an organizer saving a ticket type or price tier.
#
# Bumps run after the outermost transaction commits, so a reader that sees the
# new generation also sees the committed inventory. Checkout never trusts this
# cache: it always re-reads inventory under its locks.
module PublicEventCache
  GENERATION_NAME = "public_events"
  PENDING_BUMP_KEY = :hafapass_public_event_cache_bump_pending

  module_function

  # HAFAPASS_PUBLIC_EVENT_CACHE=off is the rollback switch; anything else
  # (including unset) keeps the cache on wherever Rails.cache stores data.
  def enabled?
    !%w[off false 0 disabled].include?(ENV.fetch("HAFAPASS_PUBLIC_EVENT_CACHE", "on").strip.downcase)
  end

  # One round trip for both parts of the cache version.
  def key_version
    row = ApplicationRecord.with_connection do |connection|
      connection.select_rows(<<~SQL.squish).first
        SELECT (SELECT updated_at FROM site_settings ORDER BY id ASC LIMIT 1),
               (SELECT value FROM public_cache_generations WHERE name = #{connection.quote(GENERATION_NAME)})
      SQL
    end
    [row&.first, row&.last.to_i]
  end

  def generation
    key_version.last
  end

  # Queues one bump for the enclosing transaction; later calls while that
  # transaction is still open are no-ops, so cancelling or refunding N tickets
  # in one transaction writes the generation row once, not N times.
  #
  # The flag holds the transaction the callback was registered on. Rails moves
  # a savepoint's callbacks to its parent when the savepoint commits, and runs
  # after_rollback when it rolls back; a flag whose transaction has closed is
  # ignored, so a dropped connection can never suppress later bumps. Outside a
  # transaction it bumps immediately.
  def bump_after_commit!
    return unless enabled?

    transaction = ApplicationRecord.with_connection(&:current_transaction)
    return bump! unless transaction.open? && transaction.joinable?

    state = ActiveSupport::IsolatedExecutionState
    pending = state[PENDING_BUMP_KEY]
    return if pending&.open? && pending.connection.equal?(transaction.connection)

    state[PENDING_BUMP_KEY] = transaction
    clear = -> { state[PENDING_BUMP_KEY] = nil if state[PENDING_BUMP_KEY].equal?(transaction) }
    transaction.after_rollback(&clear)
    transaction.after_commit do
      clear.call
      bump!
    end
  end

  def bump!
    return unless enabled?

    ApplicationRecord.with_connection do |connection|
      connection.exec_update(<<~SQL.squish, "PublicEventCache Bump")
        INSERT INTO public_cache_generations (name, value, created_at, updated_at)
        VALUES (#{connection.quote(GENERATION_NAME)}, 1, NOW(), NOW())
        ON CONFLICT (name) DO UPDATE
          SET value = public_cache_generations.value + 1, updated_at = NOW()
      SQL
    end
  rescue ActiveRecord::ActiveRecordError => e
    # A missed bump leaves a public page stale for at most one TTL; never fail
    # the request or job that changed inventory.
    Rails.logger.warn({ event: "public_event_cache_bump_failed", error_class: e.class.name }.to_json)
  end
end
