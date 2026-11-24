class ValidateEmailDeliverySubjects < ActiveRecord::Migration[8.1]
  def change
    validate_check_constraint :message_deliveries, name: "message_deliveries_subject_present_email_base"
  end
end
