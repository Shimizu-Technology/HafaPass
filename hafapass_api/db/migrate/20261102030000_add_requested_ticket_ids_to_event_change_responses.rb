# frozen_string_literal: true

# A recorded event-change refund request keeps its window only for the tickets
# it named; anything else is judged at the time of a later retry.
class AddRequestedTicketIdsToEventChangeResponses < ActiveRecord::Migration[8.0]
  def change
    add_column :event_change_responses, :requested_ticket_ids, :bigint, array: true, default: [], null: false
  end
end
