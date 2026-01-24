FactoryBot.define do
  factory :ticket do
    order { nil }
    ticket_type { nil }
    event { nil }
    qr_code { "MyString" }
    status { 1 }
    attendee_name { "MyString" }
    attendee_email { "MyString" }
    checked_in_at { "2026-01-24 15:41:08" }
  end
end
