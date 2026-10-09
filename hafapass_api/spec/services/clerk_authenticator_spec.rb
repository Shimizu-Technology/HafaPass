require "rails_helper"

RSpec.describe ClerkAuthenticator do
  let(:private_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:claims) do
    { "sub" => "user_fixture", "iss" => "https://fixture.clerk.accounts.dev",
      "exp" => 5.minutes.from_now.to_i, "nbf" => 5.seconds.ago.to_i,
      "azp" => "http://localhost:5173" }
  end

  def token(payload = claims, algorithm = "RS256")
    JWT.encode(payload, private_key, algorithm)
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CLERK_ISSUER").and_return("https://fixture.clerk.accounts.dev")
    allow(ENV).to receive(:[]).with("CLERK_AUTHORIZED_PARTIES").and_return("http://localhost:5173")
    allow(ENV).to receive(:[]).with("CLERK_AUDIENCE").and_return(nil)
    allow(ENV).to receive(:[]).with("CLERK_JWKS_URL").and_return(nil)
    allow(described_class).to receive(:fetch_jwks).and_return({ "keys" => [JWT::JWK.new(private_key).export] })
  end

  it "accepts the standard Clerk session contract without an audience" do
    expect(described_class.verify(token)).to eq(claims)
  end

  it "allows absent azp according to Clerk's documented Origin-less token contract" do
    payload = claims.except("azp")
    expect(described_class.verify(token(payload))).to eq(payload)
  end

  it "rejects wrong issuer, authorized party, missing subject and missing expiry" do
    [claims.merge("iss" => "https://another.clerk.accounts.dev"),
      claims.merge("azp" => "https://untrusted.example"),
      claims.merge("azp" => nil), claims.merge("sub" => ""),
      claims.except("exp")].each do |payload|
      expect(described_class.verify(token(payload))).to be_nil
    end
  end

  it "rejects expired, not-yet-active, wrong-key and unsupported-algorithm tokens" do
    expect(described_class.verify(token(claims.merge("exp" => 1.minute.ago.to_i)))).to be_nil
    expect(described_class.verify(token(claims.merge("nbf" => 1.minute.from_now.to_i)))).to be_nil
    other = OpenSSL::PKey::RSA.generate(2048)
    expect(described_class.verify(JWT.encode(claims, other, "RS256"))).to be_nil
    expect(described_class.verify(JWT.encode(claims, nil, "none"))).to be_nil
  end

  it "verifies audience only when the deployed template explicitly configures it" do
    allow(ENV).to receive(:[]).with("CLERK_AUDIENCE").and_return("hafapass-api")
    expect(described_class.verify(token)).to be_nil
    expect(described_class.verify(token(claims.merge("aud" => "different-api")))).to be_nil
    expect(described_class.verify(token(claims.merge("aud" => "hafapass-api")))).to be_present
  end

  it "fails closed on absent or malformed issuer/production origins" do
    allow(ENV).to receive(:[]).with("CLERK_ISSUER").and_return("https://issuer.example/invalid-path")
    expect(described_class.verify(token)).to be_nil
    allow(ENV).to receive(:[]).with("CLERK_ISSUER").and_return("https://fixture.clerk.accounts.dev")
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(ENV).to receive(:[]).with("CLERK_AUTHORIZED_PARTIES").and_return(nil)
    allow(ENV).to receive(:[]).with("ALLOWED_ORIGINS").and_return(nil)
    expect(described_class.verify(token)).to be_nil
  end

  it "derives the issuer from a valid publishable key and rejects generic placeholders" do
    allow(ENV).to receive(:[]).with("CLERK_ISSUER").and_return(nil)
    allow(ENV).to receive(:[]).with("CLERK_PUBLISHABLE_KEY")
      .and_return("pk_test_#{Base64.strict_encode64('fixture.clerk.accounts.dev$').delete_suffix('=')}")
    expect(described_class.issuer).to eq("https://fixture.clerk.accounts.dev")
    expect(described_class.verify(token)).to be_present
    allow(ENV).to receive(:[]).with("CLERK_PUBLISHABLE_KEY").and_return("pk_test_xxx")
    expect(described_class.verify(token)).to be_nil
  end
end
