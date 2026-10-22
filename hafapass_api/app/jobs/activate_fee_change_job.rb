# frozen_string_literal: true

class ActivateFeeChangeJob < ApplicationJob
  def perform(_fee_change_id = nil)
    FeeChange.activate_due!(SiteSetting.first!)
  end
end
