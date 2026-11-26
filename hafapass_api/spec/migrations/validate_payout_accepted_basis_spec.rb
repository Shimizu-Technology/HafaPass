# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261126180100_validate_payout_accepted_basis")

# CodeRabbit 4707205528 / 4707205533: the acceptance marker and its basis are
# set together or not at all, enforced by the CHECK itself (a NULL basis
# beside a timestamp is FALSE, not UNKNOWN), and rolling the validation back
# restores the NOT VALID constraint 20261126180000 added. Each example runs
# in the test transaction (PostgreSQL DDL is transactional) and is rolled
# back, leaving the validated constraint in place.
RSpec.describe ValidatePayoutAcceptedBasis do
  let(:connection) { ActiveRecord::Base.connection }
  let(:name) { "payouts_provider_accepted_basis_valid" }

  def validated?
    connection.select_value("SELECT convalidated FROM pg_constraint WHERE conname = #{connection.quote(name)}")
  end

  it "rolls back to the same NOT VALID constraint and validates it again" do
    expect(validated?).to be(true)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:down) }
    expect(validated?).to be(false)
    # The same rule (PostgreSQL may spell the IN-list casts differently).
    expect(connection.select_value("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = #{connection.quote(name)}"))
      .to start_with("CHECK ((((provider_accepted_basis IS NOT NULL) AND (provider_accepted_at IS NOT NULL) AND")
      .and end_with("OR ((provider_accepted_basis IS NULL) AND (provider_accepted_at IS NULL)))) NOT VALID")
    # In production the two directions run as separate migrations; here
    # both run in one test transaction, which strong_migrations flags.
    StrongMigrations::Checker.safety_assured do
      ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
    end
    expect(validated?).to be(true)
  end

  it "rejects either half of the pair on its own, without the row triggers" do
    payout = create(:payout)
    # Only the CHECK decides here: the payout row triggers are disabled in
    # this rolled-back test transaction.
    connection.execute("ALTER TABLE payouts DISABLE TRIGGER USER")
    attempt = lambda do |columns|
      connection.transaction(requires_new: true) { Payout.where(id: payout.id).update_all(columns) }
      :accepted
    rescue ActiveRecord::StatementInvalid => e
      e.message[/violates check constraint "#{name}"/] ? :refused : raise
    end
    expect(attempt.call(provider_accepted_at: Time.current, provider_accepted_basis: nil)).to eq(:refused)
    expect(attempt.call(provider_accepted_at: nil, provider_accepted_basis: "locally_observed")).to eq(:refused)
    expect(attempt.call(provider_accepted_at: Time.current, provider_accepted_basis: "guessed")).to eq(:refused)
    expect(attempt.call(provider_accepted_at: Time.current, provider_accepted_basis: "provider_reported")).to eq(:accepted)
    expect(attempt.call(provider_accepted_at: Time.current, provider_accepted_basis: "locally_observed")).to eq(:accepted)
    expect(attempt.call(provider_accepted_at: nil, provider_accepted_basis: nil)).to eq(:accepted)
  ensure
    connection.execute("ALTER TABLE payouts ENABLE TRIGGER USER")
  end
end
