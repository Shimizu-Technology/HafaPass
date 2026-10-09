require "rails_helper"
require "timeout"
require Rails.root.join("db/migrate/20261010050000_index_unowned_orders_for_guest_recovery")

RSpec.describe IndexUnownedOrdersForGuestRecovery, :non_transactional do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:index_name) { described_class::INDEX_NAME }

  before do
    raise "Migration specs must only run in test" unless Rails.env.test?

    migration.down
  end

  after { migration.up }

  it "creates the valid partial expression index and rolls back concurrently" do
    migration.up
    index = connection.indexes(:orders).find { |entry| entry.name == index_name }
    expect(index).to be_valid
    expect(index.columns).to include("lower", "btrim", "buyer_email")
    expect(index.where).to eq("(user_id IS NULL)")

    migration.down
    expect(connection.indexes(:orders).map(&:name)).not_to include(index_name)
    expect { migration.down }.not_to raise_error
  end

  it "preserves a valid existing index on retry" do
    migration.up
    oid = index_oid
    migration.up
    expect(index_oid).to eq(oid)
    expect(connection.indexes(:orders).find { |entry| entry.name == index_name }).to be_valid
  end

  it "rebuilds an invalid index left by a genuinely canceled concurrent build" do
    create_interrupted_index
    invalid = connection.indexes(:orders).find { |entry| entry.name == index_name }
    expect(invalid).not_to be_valid
    invalid_oid = index_oid

    migration.up
    expect(connection.indexes(:orders).find { |entry| entry.name == index_name }).to be_valid
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
    locker.exec("LOCK TABLE orders IN ROW EXCLUSIVE MODE")
    outcome = Queue.new
    worker = Thread.new do
      builder.exec("CREATE INDEX CONCURRENTLY #{index_name} ON orders (LOWER(BTRIM(buyer_email))) WHERE user_id IS NULL")
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
