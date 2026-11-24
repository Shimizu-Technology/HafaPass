require "rails_helper"
require "timeout"
require Rails.root.join("db/migrate/20261124150000_review_email_readiness")
require Rails.root.join("db/migrate/20261124150100_index_email_delivery_recipients")

RSpec.describe IndexEmailDeliveryRecipients, :non_transactional do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:index_name) { described_class::INDEX_NAME }

  before do
    raise "Migration specs must only run in test" unless Rails.env.test?

    migration.down
  end

  after { migration.up }

  it "creates the valid expression index and rolls back concurrently" do
    migration.up
    index = connection.indexes(:message_deliveries).find { |entry| entry.name == index_name }
    expect(index).to be_valid
    expect(index.columns).to include("lower", "recipient")

    migration.down
    expect(connection.indexes(:message_deliveries).map(&:name)).not_to include(index_name)
    expect { migration.down }.not_to raise_error
  end

  it "retries index work after columns commit and a concurrent build fails" do
    columns = ReviewEmailReadiness.new
    columns.migrate(:down)
    connection.transaction { columns.migrate(:up) }
    allow(migration).to receive(:add_index).and_raise("interrupted build")
    expect { migration.up }.to raise_error("interrupted build")
    expect(connection.column_exists?(:audience_mailings, :filters)).to be(true)
    allow(migration).to receive(:add_index).and_call_original
    migration.up
    migration.up
    expect(connection.indexes(:message_deliveries).find { |entry| entry.name == index_name }).to be_valid
  end

  it "preserves a valid existing index on retry" do
    migration.up
    oid = index_oid
    migration.up
    expect(index_oid).to eq(oid)
    expect(connection.indexes(:message_deliveries).find { |entry| entry.name == index_name }).to be_valid
  end

  it "rebuilds an invalid index left by a genuinely canceled concurrent build" do
    create_interrupted_index
    invalid = connection.indexes(:message_deliveries).find { |entry| entry.name == index_name }
    expect(invalid).not_to be_valid
    invalid_oid = index_oid

    migration.up
    expect(connection.indexes(:message_deliveries).find { |entry| entry.name == index_name }).to be_valid
    expect(index_oid).not_to eq(invalid_oid)
    migration.down
    expect(index_oid).to be_nil
  end

  def index_oid
    connection.select_value("SELECT to_regclass(#{connection.quote(index_name)})::oid")
  end

  def create_interrupted_index
    options = connection.pool.db_config.configuration_hash.slice(:host, :port, :database, :username, :password)
      .transform_keys { |key| { database: :dbname, username: :user }.fetch(key, key) }
    locker = PG.connect(options)
    builder = PG.connect(options)
    locker.exec("BEGIN")
    locker.exec("LOCK TABLE message_deliveries IN ROW EXCLUSIVE MODE")
    outcome = Queue.new
    worker = Thread.new do
      builder.exec("CREATE INDEX CONCURRENTLY #{index_name} ON message_deliveries (lower(recipient))")
      outcome << :completed
    rescue PG::QueryCanceled => error
      outcome << error
    end
    Timeout.timeout(15) do
      sleep 0.02 until index_oid.present?
      connection.execute("SELECT pg_cancel_backend(#{builder.backend_pid})")
      worker.join
      expect(outcome.pop).to be_a(PG::QueryCanceled)
    end
  ensure
    locker&.close
    builder&.cancel if worker&.alive?
    worker&.join(5)
    builder&.close
  end
end
