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

  it "requires a dedicated production authorized-party allowlist despite valid CORS origins" do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(ENV).to receive(:[]).with("CLERK_AUTHORIZED_PARTIES").and_return(nil)
    allow(ENV).to receive(:[]).with("ALLOWED_ORIGINS").and_return("https://web.example")
    expect(described_class.verify(token(claims.merge("azp" => "https://web.example")))).to be_nil
    allow(ENV).to receive(:[]).with("CLERK_AUTHORIZED_PARTIES").and_return("https://web.example/")
    expect(described_class.verify(token(claims.merge("azp" => "https://web.example")))).to be_present
    expect(described_class.verify(token(claims.merge("azp" => "https://cors-only.example")))).to be_nil
  end

  it "retains the explicit CORS fallback only for non-production test runtimes" do
    allow(ENV).to receive(:[]).with("CLERK_AUTHORIZED_PARTIES").and_return(nil)
    allow(ENV).to receive(:[]).with("ALLOWED_ORIGINS").and_return("http://localhost:5173")
    expect(described_class.verify(token)).to be_present
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

  describe "JWKS key selection and caching" do
    include ActiveSupport::Testing::TimeHelpers

    let(:rotated_key) { OpenSSL::PKey::RSA.generate(2048) }
    let(:published) { { "keys" => [JWT::JWK.new(private_key, kid: "kid-a").export.stringify_keys] } }
    let(:rotated) { { "keys" => published["keys"] + [JWT::JWK.new(rotated_key, kid: "kid-b").export.stringify_keys] } }

    let(:verified) { include("sub" => "user_fixture") }

    # Fresh timestamps so a token is still valid after travelling in time.
    def signed(key, kid)
      JWT.encode(claims.merge("exp" => 5.minutes.from_now.to_i, "nbf" => 5.seconds.ago.to_i), key, "RS256", { kid: kid })
    end

    before do
      described_class.reset_jwks_cache!
      allow(described_class).to receive(:fetch_jwks).and_call_original
    end

    after { described_class.reset_jwks_cache! }

    it "verifies only with the key the token names" do
      allow(described_class).to receive(:fetch_jwks_from_clerk).and_return(rotated)
      expect(described_class.verify(signed(rotated_key, "kid-b"))).to verified
      # Signed by key A while claiming key B's kid: key A is never tried.
      expect(described_class.verify(signed(private_key, "kid-b"))).to be_nil
      expect(described_class).to have_received(:fetch_jwks_from_clerk).once
    end

    it "refetches once for an unknown kid, then at most every five minutes" do
      allow(described_class).to receive(:fetch_jwks_from_clerk).and_return(published, rotated)
      freeze_time do
        expect(described_class.verify(signed(private_key, "kid-a"))).to verified
        expect(described_class.verify(signed(rotated_key, "kid-b"))).to verified
        expect(described_class).to have_received(:fetch_jwks_from_clerk).twice

        expect(described_class.verify(signed(rotated_key, "kid-unknown"))).to be_nil
        expect(described_class.verify(signed(rotated_key, "kid-forged"))).to be_nil
        expect(described_class).to have_received(:fetch_jwks_from_clerk).twice

        travel 5.minutes + 1.second
        expect(described_class.verify(signed(rotated_key, "kid-unknown"))).to be_nil
        expect(described_class).to have_received(:fetch_jwks_from_clerk).exactly(3).times
      end
    end

    it "keeps serving the last good key set for a day when Clerk is unreachable, caching the failure" do
      calls = 0
      allow(described_class).to receive(:fetch_jwks_from_clerk) { (calls += 1) == 1 ? published : nil }
      freeze_time do
        expect(described_class.verify(signed(private_key, "kid-a"))).to verified

        travel 1.hour + 1.second
        expect(described_class.verify(signed(private_key, "kid-a"))).to verified
        expect(calls).to eq(2)
        # The failure is cached: no request waits on Clerk again for 30 seconds.
        travel 29.seconds
        expect(described_class.verify(signed(private_key, "kid-a"))).to verified
        expect(calls).to eq(2)
        travel 2.seconds
        expect(described_class.verify(signed(private_key, "kid-a"))).to verified
        expect(calls).to eq(3)

        travel 23.hours
        expect(described_class.verify(signed(private_key, "kid-a"))).to be_nil
      end
    end

    it "does not cache a failed first fetch beyond the failure window" do
      allow(described_class).to receive(:fetch_jwks_from_clerk).and_return(nil, published)
      freeze_time do
        expect(described_class.verify(signed(private_key, "kid-a"))).to be_nil
        expect(described_class.verify(signed(private_key, "kid-a"))).to be_nil
        expect(described_class).to have_received(:fetch_jwks_from_clerk).once
        travel 31.seconds
        expect(described_class.verify(signed(private_key, "kid-a"))).to verified
      end
    end

    it "fetches once when concurrent requests find the cache empty" do
      calls = Concurrent::AtomicFixnum.new
      allow(described_class).to receive(:fetch_jwks_from_clerk) do
        calls.increment
        sleep 0.05
        published
      end
      results = Array.new(5) { Thread.new { described_class.verify(signed(private_key, "kid-a")) } }.map(&:value)
      expect(results).to all(verified)
      expect(calls.value).to eq(1)
    end
  end
end
