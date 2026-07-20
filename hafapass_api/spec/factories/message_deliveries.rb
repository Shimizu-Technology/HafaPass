FactoryBot.define do
  factory :message_delivery do
    association :order
    channel { "email" }
    template { "order_confirmation" }
    recipient { order.buyer_email }
    status { :queued }
  end
end
