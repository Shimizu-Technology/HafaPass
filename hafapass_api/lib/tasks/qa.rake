# frozen_string_literal: true

namespace :qa do
  desc "Create repeatable synthetic fixtures in an explicitly isolated local hafapass_qa_* database"
  task seed: :environment do
    require Rails.root.join("lib/qa/fixtures")
    identities = Qa::Fixtures::ROLES.filter_map do |role|
      subject = ENV["HAFAPASS_QA_#{role.upcase}_CLERK_ID"].presence
      [role, subject] if subject
    end.to_h
    puts JSON.pretty_generate(Qa::Fixtures.call(identities: identities))
  end
end
