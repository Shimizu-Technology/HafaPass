# frozen_string_literal: true

class Api::V1::Admin::ActivityLogExportsController < Api::V1::Admin::BaseController
  include ActivityLogExports

  private

  def export_admin? = true
end
