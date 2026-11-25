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
    expect(options[:solid_queue_mode]).to eq(:async)
    expect([options[:min_threads], options[:max_threads]]).to eq([3, 3])
  end

  it "runs WEB_CONCURRENCY workers from a preloaded master when set above one" do
    options = puma_options("WEB_CONCURRENCY" => "3", "RAILS_MAX_THREADS" => "5", "HAFAPASS_RUNTIME" => "embedded", "DB_POOL" => "11")

    expect(options[:workers]).to eq(3)
    expect(options[:preload_app]).to be(true)
    expect([options[:min_threads], options[:max_threads]]).to eq([5, 5])
    # The master closes its preload connections and runs no job threads: the
    # supervisor starts in worker 0, so a respawned worker forks cleanly.
    expect(options.all_of(:before_fork)).not_to be_empty
    expect(options.all_of(:before_worker_boot)).not_to be_empty
    expect(options.all_of(:before_worker_shutdown)).not_to be_empty
    expect(options[:solid_queue_mode]).to be_nil
  end

  it "registers no queue hooks in cluster mode without the embedded runtime" do
    options = puma_options("WEB_CONCURRENCY" => "2", "RAILS_MAX_THREADS" => "5", "HAFAPASS_RUNTIME" => "solid_queue", "DB_POOL" => "11")

    expect(options[:workers]).to eq(2)
    expect(options.all_of(:before_fork)).not_to be_empty
    expect(options.all_of(:before_worker_boot)).to be_empty
    expect(options[:solid_queue_mode]).to be_nil
  end

  it "flushes buffered rejected-webhook counts when a cluster worker shuts down, with or without the embedded runtime" do
    options = puma_options("WEB_CONCURRENCY" => "2", "RAILS_MAX_THREADS" => "5", "HAFAPASS_RUNTIME" => "solid_queue", "DB_POOL" => "11")
    hooks = options.all_of(:before_worker_shutdown)
    expect(hooks).not_to be_empty

    allow(Operations::WebhookRejections).to receive(:flush!)
    hooks.each { |hook| hook.respond_to?(:call) ? hook.call(0) : hook[:block].call(0) }
    expect(Operations::WebhookRejections).to have_received(:flush!).at_least(:once)
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

  def wait_for(seconds, log)
    Timeout.timeout(seconds) do
      loop do
        result = yield
        return result if result

        raise "Puma exited early:\n#{File.read(log.path)}" if Process.waitpid(@puma_pid, Process::WNOHANG)

        sleep 0.5
      end
    end
  end

  # Every request must be answered: a worker forked holding a dead thread's
  # mutex would hang on its first database query. Readiness queries the
  # database (503 is expected here: no release revision is configured).
  def expect_database_requests_answered(port)
    8.times do
      code = Net::HTTP.start("127.0.0.1", port, read_timeout: 10) { |http| http.get("/api/v1/readiness").code }
      expect(%w[200 503]).to include(code)
    end
  end

  it "starts exactly one supervisor, in request worker 0 and never the master, and survives worker respawns" do
    port = free_port
    env = {
      "RAILS_ENV" => "test", "DATABASE_URL" => ENV["DATABASE_URL"], "HAFAPASS_RUNTIME" => "embedded",
      "WEB_CONCURRENCY" => "2", "RAILS_MAX_THREADS" => "2", "DB_POOL" => "8", "PORT" => port.to_s,
      # macOS only: its Objective-C runtime aborts forked children without this.
      "OBJC_DISABLE_INITIALIZE_FORK_SAFETY" => "YES", "PGGSSENCMODE" => "disable"
    }
    log = Tempfile.new("puma-cluster")
    pid = @puma_pid = Process.spawn(env, "bundle", "exec", "puma", "-C", "config/puma.rb", chdir: Rails.root.to_s,
      out: log.path, err: log.path, pgroup: true)

    wait_for(90, log) do
      kinds = SolidQueue::Process.distinct.pluck(:kind)
      (%w[Dispatcher Scheduler Supervisor(async) Worker] - kinds).empty? &&
        SolidQueue::Process.where(kind: "Worker").count == 2 && child_pids(pid).size == 2
    end
    # A supervisor started per worker would register within the same boot.
    sleep 3
    processes = SolidQueue::Process.order(:id).to_a

    supervisor = processes.find { |process| process.kind == "Supervisor(async)" }
    workers = child_pids(pid)
    # Transactional and marketing lanes each have their own queue worker.
    expect(processes.map(&:kind).tally).to eq("Dispatcher" => 1, "Scheduler" => 1, "Supervisor(async)" => 1, "Worker" => 2)
    expect(processes.map(&:pid).uniq).to eq([supervisor.pid])
    expect(workers).to include(supervisor.pid)
    expect(processes.map(&:pid)).not_to include(pid)
    expect(processes.reject { |process| process == supervisor }.map(&:supervisor_id)).to all(eq(supervisor.id))
    expect(processes.map { |process| process.metadata["runtime_instance"] }.uniq.size).to eq(1)
    expect(workers.size).to eq(2)
    3.times do
      expect(Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/up")).code).to eq("200")
    end
    expect_database_requests_answered(port)

    # A request worker without the supervisor dies: Puma forks its
    # replacement from the master, the queue keeps its one supervisor.
    plain_worker = (workers - [supervisor.pid]).first
    Process.kill("KILL", plain_worker)
    wait_for(60, log) { (child_pids(pid) - [plain_worker]).size == 2 }
    expect_database_requests_answered(port)
    sleep 2
    expect(SolidQueue::Process.order(:id).to_a).to eq(processes)

    # Worker 0 dies with the supervisor: its replacement starts a new one,
    # with the same runtime instance, and still never in the master.
    Process.kill("KILL", supervisor.pid)
    replacement = wait_for(60, log) do
      SolidQueue::Process.where(kind: "Supervisor(async)").where.not(pid: supervisor.pid).first
    end
    expect(child_pids(pid)).to include(replacement.pid)
    expect(replacement.pid).not_to eq(pid)
    expect(replacement.metadata["runtime_instance"]).to eq(supervisor.metadata["runtime_instance"])
    wait_for(30, log) do
      SolidQueue::Process.where(pid: replacement.pid).pluck(:kind).tally ==
        { "Dispatcher" => 1, "Scheduler" => 1, "Supervisor(async)" => 1, "Worker" => 2 }
    end
    expect_database_requests_answered(port)
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
