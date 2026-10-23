require "rails_helper"
require "timeout"

# One save retires a link name into the redirect table while another claims
# the same name. No unique index spans both tables, so only the advisory lock
# taken inside the save keeps the name from ending up live on one event and
# redirecting from another.
RSpec.describe "Link name claims under concurrency", :non_transactional do
  self.use_transactional_tests = false

  before { clean_test_data }
  after { clean_test_data }

  it "rejects a claim on a name that a concurrent rename is retiring" do
    retiring = create(:event, :published, title: "Island Fest")
    claimant = create(:event, :published, title: "Other Fest")
    # The claimant's validation ran before the rename committed and saw the
    # name as free (the stale check the lock exists to correct).
    allow(Event).to receive(:public_slug_problem).and_return(nil)

    renamed = Queue.new
    release = Queue.new
    rename = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Event.transaction do
          Event.find(retiring.id).update!(slug: "island-fest-2026")
          renamed << true
          Timeout.timeout(10) { release.pop }
        end
      end
    end
    Timeout.timeout(5) { renamed.pop }

    claim = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        event = Event.find(claimant.id)
        [event.update(slug: "island-fest"), event.errors.full_messages]
      end
    end
    Timeout.timeout(5) do
      sleep 0.05 until ActiveRecord::Base.connection.select_value(
        "SELECT COUNT(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted"
      ).to_i.positive?
    end
    release << true
    rename.join(10)
    saved, errors = claim.value

    expect(saved).to be(false)
    expect(errors).to include("Event link is already used by another event")
    expect(EventSlugRedirect.find_by!(slug: "island-fest").event_id).to eq(retiring.id)
    expect(claimant.reload.slug).to eq("other-fest")
    expect(Event.where(slug: EventSlugRedirect.select(:slug))).to be_empty
  end

  it "gives a generated link a fresh suffix when a concurrent rename retires its name" do
    retiring = create(:event, :published, title: "Island Fest")
    allow(Event).to receive(:public_slug_taken?).and_call_original
    # The draft's generation saw the name as free before the rename committed.
    allow(Event).to receive(:public_slug_taken?).with("island-fest", record: anything).and_return(false, true)

    Event.transaction do
      Event.find(retiring.id).update!(slug: "island-fest-2026")
    end
    draft = create(:event, title: "Island Fest", organizer_profile: retiring.organizer_profile)

    expect(draft.slug).to match(/\Aisland-fest-[a-f0-9]{6}\z/)
    expect(Event.where(slug: EventSlugRedirect.select(:slug))).to be_empty
  end

  def clean_test_data
    unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.end_with?("_test")
      raise "Isolated test database required"
    end

    ActiveRecord::Base.connection.execute(<<~SQL)
      TRUNCATE TABLE audit_logs, audit_write_failures, users, organizations, organizer_profiles, events, event_slug_redirects, venues, site_settings
      RESTART IDENTITY CASCADE
    SQL
  end
end
