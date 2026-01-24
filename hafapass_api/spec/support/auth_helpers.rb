module AuthHelpers
  def auth_headers(user)
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
