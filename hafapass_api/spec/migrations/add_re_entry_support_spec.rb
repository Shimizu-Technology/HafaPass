# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261124200000_add_re_entry_support")
require Rails.root.join("db/migrate/20261124200100_validate_re_entry_constraints")

RSpec.describe AddReEntrySupport do
  it "enforces re-entry check constraints and defaults on existing records" do
    event = create(:event)
    ticket = create(:ticket, event: event, order: create(:order, event: event), ticket_type: create(:ticket_type, event: event))

    expect(event).to have_attributes(re_entry_mode: "off", re_entry_max_count: nil, re_entry_cutoff_at: nil, re_entry_cooldown_minutes: nil)
    expect(ticket).to have_attributes(occupancy_state: "outside", occupancy_day: nil, re_entry_count: 0, re_entry_conflict_flagged: false)

    expect do
      Event.transaction(requires_new: true) { event.update_columns(re_entry_mode: "invalid") }
    end.to raise_error(ActiveRecord::StatementInvalid, /events_re_entry_mode_valid/)

    expect do
      Ticket.transaction(requires_new: true) { ticket.update_columns(occupancy_state: "invalid") }
    end.to raise_error(ActiveRecord::StatementInvalid, /tickets_occupancy_state_valid/)

    expect do
      Ticket.transaction(requires_new: true) { ticket.update_columns(re_entry_count: -1) }
    end.to raise_error(ActiveRecord::StatementInvalid, /tickets_re_entry_count_non_negative/)
  end
end
