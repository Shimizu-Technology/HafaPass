# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Rails eager loading" do
  it "loads every application constant without executing process entrypoints" do
    expect { Rails.application.eager_load! }.not_to raise_error
  end
end
