# frozen_string_literal: true

class AddReserveReleaseOnToBalanceAdjustments < ActiveRecord::Migration[8.1]
  def change
    # The release date agreed when a chargeback reserve is held. Immutable once
    # posted; it governs the release even if the event is edited later. Null
    # for older hand-entered holds, which fall back to 30 days after the event.
    add_column :balance_adjustments, :reserve_release_on, :date
  end
end
