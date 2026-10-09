module AuthHelpers
  def auth_headers(user)
    # Snapshot provider identity separately from later editable contact changes.
    allow(ClerkIdentity).to receive(:verified_email_addresses).with(user.clerk_id).and_return([user.email.to_s.downcase])
    token = "test_token_#{user.clerk_id}"
    allow(ClerkAuthenticator).to receive(:verify).with(token).and_return({
      "sub" => user.clerk_id,
      "email" => user.email,
      "first_name" => user.first_name,
      "last_name" => user.last_name
    })
    { "Authorization" => "Bearer #{token}" }
  end
end

RSpec.configure do |config|
  config.include AuthHelpers, type: :request
end
