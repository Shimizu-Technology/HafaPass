require "rails_helper"
require "stringio"

RSpec.describe S3Service do
  let(:client) { Aws::S3::Client.new(stub_responses: true, region: "us-west-2", credentials: Aws::Credentials.new("fixture", "fixture")) }

  before do
    allow(described_class).to receive(:s3_client).and_return(client)
    allow(described_class).to receive(:bucket_name).and_return("fixture-bucket")
    allow(described_class).to receive(:configured?).and_return(true)
  end

  it "creates independent immutable keys for simultaneous matching filenames" do
    keys = 5.times.map { described_class.send(:build_key, "poster.jpg", event_id: 987) }
    expect(keys.uniq.length).to eq(5)
    expect(keys).to all(match(%r{\Auploads/events/987/[0-9a-f-]{36}\.jpg\z}))
    expect(described_class.send(:build_key, "../../evil.jpg", organization_id: 77)).to start_with("uploads/organizations/77/")
  end

  it "rejects dangerous types, empty files, malformed sizes and files over 5 MB" do
    ["image/svg+xml", "image/gif", "text/html"].each do |type|
      expect { described_class.generate_presigned_post("file", type, byte_size: 100) }.to raise_error(described_class::UploadError)
    end
    [nil, "invalid", 0, -1, 5.megabytes + 1].each do |size|
      expect { described_class.generate_presigned_post("file.jpg", "image/jpeg", byte_size: size) }.to raise_error(described_class::UploadError)
    end
    expect(client.api_requests).to be_empty
  end

  it "signs a bounded upload to a pending key without a prematurely published URL" do
    bucket = instance_double(Aws::S3::Bucket)
    post = double(url: "https://fixture.invalid", fields: { "key" => "pending" })
    allow(described_class).to receive(:s3_bucket).and_return(bucket)
    allow(bucket).to receive(:presigned_post).and_return(post)
    result = described_class.generate_presigned_post("file.jpg", "image/jpeg", byte_size: 100, organization_id: 1)
    expect(result).not_to have_key(:public_url)
    expect(result[:key]).to start_with("pending/organizations/1/")
    expect(bucket).to have_received(:presigned_post).with(hash_including(content_type: "image/jpeg", content_length_range: 1..100))
  end

  it "verifies bytes and atomically copies the validated source to a new immutable key" do
    client.stub_responses(:head_object, content_type: "image/jpeg", content_length: 100, etag: "source-version")
    client.stub_responses(:get_object, body: "\xFF\xD8\xFFfixture".b)
    result = described_class.complete_upload(key: "pending/image.jpg", content_type: "image/jpeg", byte_size: 100, event_id: 1)
    get = client.api_requests.find { |entry| entry[:operation_name] == :get_object }
    copy = client.api_requests.find { |entry| entry[:operation_name] == :copy_object }
    expect(get[:params]).to include(if_match: "source-version", range: "bytes=0-15")
    expect(copy[:params]).to include(copy_source_if_match: "source-version", copy_source: "fixture-bucket/pending/image.jpg", content_type: "image/jpeg")
    expect(result[:key]).to start_with("uploads/events/1/")
    expect(copy[:params][:key]).to eq(result[:key])
  end

  it "rejects mismatched size/type and renamed non-image bytes without publishing" do
    client.stub_responses(:head_object, content_type: "text/html", content_length: 100)
    expect { described_class.complete_upload(key: "pending/image.jpg", content_type: "image/jpeg", byte_size: 100) }.to raise_error(described_class::UploadError)
    client.stub_responses(:head_object, content_type: "image/jpeg", content_length: 101)
    expect { described_class.complete_upload(key: "pending/image.jpg", content_type: "image/jpeg", byte_size: 100) }.to raise_error(described_class::UploadError)
    client.stub_responses(:head_object, content_type: "image/jpeg", content_length: 100)
    client.stub_responses(:get_object, body: "<html>bad</html>")
    expect { described_class.complete_upload(key: "pending/image.jpg", content_type: "image/jpeg", byte_size: 100) }.to raise_error(described_class::UploadError)
    expect(client.api_requests.map { |entry| entry[:operation_name] }).not_to include(:copy_object)
  end

  it "fails closed if the verified source is replaced before copy" do
    client.stub_responses(:head_object, content_type: "image/png", content_length: 100, etag: "old")
    client.stub_responses(:get_object, body: "\x89PNG\r\n\x1A\nfixture".b)
    client.stub_responses(:copy_object, "PreconditionFailed")
    expect { described_class.complete_upload(key: "pending/image.png", content_type: "image/png", byte_size: 100) }.to raise_error(described_class::UploadError, /could not be verified/)
  end
end
