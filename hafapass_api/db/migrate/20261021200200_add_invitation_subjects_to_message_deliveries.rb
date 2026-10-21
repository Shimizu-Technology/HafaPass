# frozen_string_literal: true

# Invitation emails go through the same durable MessageDelivery pipeline as
# ticket mail, so they need a subject other than an order, ticket or event.
# Existing rows already satisfy the widened constraint.
class AddInvitationSubjectsToMessageDeliveries < ActiveRecord::Migration[8.1]
  def up
    add_reference :message_deliveries, :organization_membership, foreign_key: true, index: true
    add_reference :message_deliveries, :platform_invitation, foreign_key: true, index: true
    remove_check_constraint :message_deliveries, name: "message_deliveries_subject_present"
    add_check_constraint :message_deliveries,
      "order_id IS NOT NULL OR ticket_id IS NOT NULL OR event_id IS NOT NULL OR " \
      "organization_membership_id IS NOT NULL OR platform_invitation_id IS NOT NULL",
      name: "message_deliveries_subject_present"
  end

  def down
    if select_value("SELECT 1 FROM message_deliveries WHERE order_id IS NULL AND ticket_id IS NULL AND event_id IS NULL LIMIT 1")
      raise ActiveRecord::IrreversibleMigration,
        "Invitation-only email deliveries exist; archive or remove them before rolling back"
    end

    remove_check_constraint :message_deliveries, name: "message_deliveries_subject_present"
    add_check_constraint :message_deliveries, "order_id IS NOT NULL OR ticket_id IS NOT NULL OR event_id IS NOT NULL",
      name: "message_deliveries_subject_present"
    remove_reference :message_deliveries, :platform_invitation, foreign_key: true, index: true
    remove_reference :message_deliveries, :organization_membership, foreign_key: true, index: true
  end
end
