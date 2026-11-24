# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "hafapass:monitoring:test_alert" do
  let(:task) { Rake::Task["hafapass:monitoring:test_alert"] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("hafapass:monitoring:test_alert")
    task.reenable
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SENTRY_DSN").and_return("https://public@example.invalid/1")
  end

  it "queues a labelled test event and uses the same cooldown as the admin button" do
    allow(Sentry).to receive(:capture_message).and_return(instance_double(Sentry::Event, event_id: "evt1"))
    expect { task.execute(Rake::TaskArguments.new([:kind], ["checkout"])) }.to output(/Queued test alert checkout/).to_stdout
    expect(Sentry).to have_received(:capture_message).with(/\[TEST\]/, hash_including(tags: hash_including(monitoring_test: "true")))

    expect { task.execute(Rake::TaskArguments.new([:kind], ["checkout"])) }.to raise_error(SystemExit).and output(/wait and retry/).to_stderr
  end

  it "fails when Sentry queues nothing, and frees the cooldown" do
    allow(Sentry).to receive(:capture_message).and_return(nil)
    expect { task.execute(Rake::TaskArguments.new([:kind], ["checkout"])) }.to raise_error(SystemExit).and output(/did not accept/).to_stderr
    expect(MonitoringTestAlert.claim_slot!).to be(true)
  end

  it "rejects unknown kinds" do
    expect { task.execute(Rake::TaskArguments.new([:kind], ["nope"])) }.to raise_error(SystemExit).and output(/Choose one of/).to_stderr
  end
end
