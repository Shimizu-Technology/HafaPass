# frozen_string_literal: true

class DefaultEventSeriesExcludeDoorCash < ActiveRecord::Migration[8.1]
  def change
    change_column_default :event_series, :revenue_share_includes_door_cash, from: true, to: false
  end
end
