# frozen_string_literal: true

require "rails_helper"
require "open3"
require "socket"
require "timeout"
require "net/http"
require "puma"
require "puma/configuration"

RSpec.describe "Puma process configuration" do
  around do |example|
    names = %w[WEB_CONCURRENCY RAILS_MAX_THREADS DB_POOL HAFAPASS_RUNTIME]
    original = names.index_with { |name| ENV[name] }
    example.run
  ensure
    original.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  def puma_options(env)
    env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    configuration = Puma::Configuration.new({}, {}, ENV.to_h) do |user_config|
      user_config.load Rails.root.join("config/puma.rb").to_s
    end
    configuration.clamp
    configuration.options
  end

  it "keeps the default single process, as on the 512 MB plan" do
    options = puma_options("WEB_CONCURRENCY" => nil, "RAILS_MAX_THREADS" => "3", "HAFAPASS_RUNTIME" => "embedded", "DB_POOL" => "10")

    expect(options[:workers]).to eq(0)
    expect(options[:preload_app]).to be_falsey
    expect([options[:min_threads], options[:max_threads]]).to eq([3, 3])
  end

  it "runs WEB_CONCURRENCY workers from a preloaded master when set above one" do
    options = puma_options("WEB_CONCURRENCY" => "3", "RAILS_MAX_THREADS" => "5", "HAFAPASS_RUNTIME" => "embedded", "DB_POOL" => "11")

    expect(options[:workers]).to eq(3)
    expect(options[:preload_app]).to be(true)
    expect(options[:solid_queue_mode]).to eq(:async)
    expect([options[:min_threads], options[:max_threads]]).to eq([5, 5])
  end

  it "rejects a process count that is not a positive integer" do
    %w[0 -1 auto 2x].each do |value|
      ENV["WEB_CONCURRENCY"] = value
      expect { RuntimeConfiguration.web_processes }.to raise_error(ArgumentError, /WEB_CONCURRENCY must be a positive integer/)
    end
  end

  it "keeps one runtime instance id across forked workers so readiness matches the master's queue heartbeats" do
    skip "fork unavailable" unless Process.respond_to?(:fork)

    master_id = RuntimeConfiguration.instance_id
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      writer.write(RuntimeConfiguration.instance_id)
      writer.close
      exit!(0)
    end
    writer.close
    child_id = reader.read
    Process.wait(pid)

    expect(child_id).to eq(master_id)
  end
end

# Boots the real config in cluster mode against the isolated test database and
# counts the Solid Queue processes it registers.
RSpec.describe "Embedded Solid Queue under clustered Puma", :non_transactional do
  self.use_transactional_tests = false

  QUEUE_TABLES = %w[solid_queue_processes solid_queue_claimed_executions solid_queue_ready_executions
    solid_queue_scheduled_executions solid_queue_recurring_executions solid_queue_jobs].freeze

  before { clean_queue_tables }
  after { clean_queue_tables }

  def clean_queue_tables
    raise "Isolated test database required" unless ActiveRecord::Base.connection_db_config.database.end_with?("_test")

    ActiveRecord::Base.connection.execute("TRUNCATE TABLE #{QUEUE_TABLES.join(', ')} RESTART IDENTITY CASCADE")
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def child_pids(pid)
    output, = Open3.capture2("ps", "-A", "-o", "pid=,ppid=")
    output.lines.filter_map do |line|
      child, parent = line.split.map(&:to_i)
      child if parent == pid
    end
  end

  it "starts exactly one supervisor, in the Puma master, with two request workers" do
    port = free_port
    env = {
      "RAILS_ENV" => "test", "DATABASE_URL" => ENV["DATABASE_URL"], "HAFAPASS_RUNTIME" => "embedded",
      "WEB_CONCURRENCY" => "2", "RAILS_MAX_THREADS" => "2", "DB_POOL" => "8", "PORT" => port.to_s,
      # macOS only: its Objective-C runtime aborts forked children without this.
      "OBJC_DISABLE_INITIALIZE_FORK_SAFETY" => "YES", "PGGSSENCMODE" => "disable"
    }
    log = Tempfile.new("puma-cluster")
    pid = Process.spawn(env, "bundle", "exec", "puma", "-C", "config/puma.rb", chdir: Rails.root.to_s,
      out: log.path, err: log.path, pgroup: true)

    processes = nil
    Timeout.timeout(90) do
      loop do
        kinds = SolidQueue::Process.distinct.pluck(:kind)
        break if (%w[Dispatcher Scheduler Supervisor(async) Worker] - kinds).empty? && child_pids(pid).size == 2

        raise "Puma exited early:\n#{File.read(log.path)}" if Process.waitpid(pid, Process::WNOHANG)

        sleep 0.5
      end
    end
    # A supervisor started per worker would register within the same boot.
    sleep 3
    processes = SolidQueue::Process.order(:id).to_a

    supervisor = processes.find { |process| process.kind == "Supervisor(async)" }
    expect(processes.size).to eq(4)
    expect(processes.map(&:pid).uniq).to eq([pid])
    expect(processes.reject { |process| process == supervisor }.map(&:supervisor_id)).to all(eq(supervisor.id))
    expect(processes.map { |process| process.metadata["runtime_instance"] }.uniq.size).to eq(1)
    workers = child_pids(pid)
    expect(workers.size).to eq(2)
    expect(workers).not_to include(*processes.map(&:pid))
    3.times do
      expect(Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/up")).code).to eq("200")
    end
  ensure
    if pid
      begin
        Process.kill("TERM", pid)
        Timeout.timeout(45) { Process.wait(pid) }
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      rescue Timeout::Error
        Process.kill("KILL", -pid)
        Process.wait(pid)
      end
    end
    log&.close!
  end
end
