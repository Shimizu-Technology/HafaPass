# frozen_string_literal: true

FactoryBot.define do
  factory :organizer_tax_information do
    association :organization
    legal_name { "Island Events LLC" }
    tax_classification { "llc_c" }
    tin_type { "ein" }
    tin { "012345678" }
    mailing_address { "PO Box 1, Hagåtña, GU 96910" }
    signer_name { "Alex Owner" }
    certified_at { Time.current }
    certification_version { OrganizerTaxInformation::CERTIFICATION_VERSION }
  end
end
