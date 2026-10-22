# frozen_string_literal: true

class AddBNoticeReceiptAndValidation < ActiveRecord::Migration[8.0]
  def change
    change_table :organizer_tax_informations, bulk: true do |t|
      t.date :irs_notice_received_on
      t.date :b_notice_send_due_on
      t.date :first_b_notice_received_on
      t.string :irs_validation_evidence_type
      t.date :irs_validation_recorded_on
      t.bigint :irs_validation_admin_id
      t.string :irs_validation_document_reference
    end
    add_foreign_key :organizer_tax_informations, :users, column: :irs_validation_admin_id
  end
end
