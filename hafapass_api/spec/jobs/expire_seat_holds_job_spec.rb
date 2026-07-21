require "rails_helper"

RSpec.describe ExpireSeatHoldsJob do
  it "expires an abandoned active session without touching consumed history" do
    configuration = create(:event_seating_configuration)
    active = configuration.seat_hold_sessions.create!(
      token_digest: Digest::SHA256.hexdigest("active-token"),
      expires_at: 1.minute.ago
    )
    consumed = configuration.seat_hold_sessions.create!(
      token_digest: Digest::SHA256.hexdigest("consumed-token"),
      status: :consumed,
      consumed_at: 1.hour.ago,
      expires_at: 1.minute.ago
    )

    described_class.perform_now(Time.current)

    expect(active.reload).to be_status_expired
    expect(consumed.reload).to be_status_consumed
  end
end
