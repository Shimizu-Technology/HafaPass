# frozen_string_literal: true

require "rails_helper"

RSpec.describe Operations::EmbeddedReadiness do
  around do |example|
    previous = ENV["HAFAPASS_RUNTIME"]
    ENV["HAFAPASS_RUNTIME"] = "embedded"
    example.run
  ensure
    ENV["HAFAPASS_RUNTIME"] = previous
  end
  def register(kind, revision: ApplicationRevision.current, at: Time.current)
    SolidQueue::Process.create!(name: "#{kind}-#{SecureRandom.hex(4)}", kind: kind, pid: 123,
      hostname: "fixture", last_heartbeat_at: at,
      metadata: { application_revision: revision, runtime_profile: "embedded", runtime_instance: RuntimeConfiguration.instance_id })
  end

  it "requires a recent worker heartbeat from the current application revision" do
    register("Worker", revision: "b" * 40)
    register("Worker", at: 2.minutes.ago)
    expect(described_class.worker[:ready]).to be(false)
    register("Worker")
    expect(described_class.worker).to include(ready: true, processes: 1)
  end

  it "rejects a still-live actor from an older Puma instance on the same release" do
    actor = register("Worker")
    actor.update!(metadata: actor.metadata.merge("runtime_instance" => "previous-instance"))
    expect(described_class.worker[:ready]).to be(false)
  end

  it "requires both actual scheduler and dispatcher plus the declared recurring tasks" do
    register("Dispatcher")
    expect(described_class.scheduler[:ready]).to be(false)
    register("Scheduler")
    expect(described_class.scheduler[:ready]).to be(false)
    schedule = YAML.safe_load(Rails.root.join("config/recurring.yml").read, aliases: true).fetch("test")
    tasks = schedule.map { |key, options| SolidQueue::RecurringTask.from_configuration(key, **options.symbolize_keys) }
    SolidQueue::RecurringTask.create_or_update_all(tasks)
    expect(described_class.scheduler[:ready]).to be(false)
    RuntimeExecution::TASKS.values.each do |key|
      RuntimeExecution.create!(task_key: key, application_revision: ApplicationRevision.current, last_succeeded_at: Time.current)
    end
    expect(described_class.scheduler[:ready]).to be(true)
  end

  it "reports stalled execution even if the worker's heartbeat is still current" do
    worker = register("Worker")
    job = SolidQueue::Job.create!(class_name: "MessageDeliveryJob", queue_name: "emails", arguments: {}, priority: 0)
    SolidQueue::ClaimedExecution.create!(job: job, process: worker, created_at: 6.minutes.ago)
    expect(described_class.worker).to include(ready: false, status: "execution_stalled")
  end

  it "keeps an older release's tick from overwriting the current candidate's progress" do
    key = "inventory_expiry"
    RuntimeExecution.create!(task_key: key, application_revision: ApplicationRevision.current, last_succeeded_at: Time.current)
    RuntimeExecution.create!(task_key: key, application_revision: "b" * 40, last_succeeded_at: Time.current)
    expect(described_class.successful_since?(key, 1.minute.ago)).to be(true)
    expect(RuntimeExecution.where(task_key: key).count).to eq(2)
  end
end
