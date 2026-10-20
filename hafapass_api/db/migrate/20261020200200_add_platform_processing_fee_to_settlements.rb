# Settlements record the actual processing cost the platform covered for
# platform-bearer orders. processing_fee_cents keeps its meaning: the cost
# deducted from organizer proceeds. Existing statements predate platform-borne
# processing, so their correct value is 0; their digests are unaffected because
# source_digest is computed from statement items only.
class AddPlatformProcessingFeeToSettlements < ActiveRecord::Migration[8.1]
  def change
    add_column :settlements, :platform_processing_fee_cents, :integer, null: false, default: 0
    add_check_constraint :settlements, "platform_processing_fee_cents >= 0",
      name: "settlements_platform_processing_fee_nonnegative"
  end
end
