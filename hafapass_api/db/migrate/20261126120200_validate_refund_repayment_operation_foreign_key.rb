# frozen_string_literal: true

class ValidateRefundRepaymentOperationForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :refunds, :repayment_operations, column: :repayment_operation_id
  end
end
