# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require_relative "../../../scripts/check_release_freeze"
require_relative "../../../scripts/release_candidate"

RSpec.describe "release candidate tooling" do
  describe HafaPass::ReleaseCandidate::Shell do
    it "runs capture and stream commands with and without a working directory" do
      Dir.mktmpdir do |directory|
        expect(described_class.new.capture!("ruby", "-e", "print 'ok'")).to eq("ok")
        expect(described_class.new.capture!("ruby", "-e", "print Dir.pwd", chdir: directory)).to eq(File.realpath(directory))
        expect { described_class.new.stream!("ruby", "-e", "exit 0") }.not_to raise_error
      end
    end
  end

  describe HafaPass::ReleaseFreeze do
    it "blocks an unlabeled pull request while the freeze is active" do
      Dir.mktmpdir do |directory|
        event = File.join(directory, "event.json")
        File.write(event, JSON.generate({ number: 42, pull_request: { number: 42, labels: [] } }))

        expect do
          described_class.verify!(freeze_id: "pilot-rc-1", event_name: "pull_request", event_path: event)
        end.to raise_error(HafaPass::ReleaseFreeze::Error, /release-approved/)
      end
    end

    it "allows a maintainer-approved pull request and non-PR candidate CI" do
      Dir.mktmpdir do |directory|
        event = File.join(directory, "event.json")
        File.write(event, JSON.generate({ pull_request: { number: 42, labels: [{ name: "release-approved" }] } }))

        expect(described_class.verify!(
          freeze_id: "pilot-rc-1", event_name: "pull_request", event_path: event
        )).to include("authorizes PR #42")
        expect(described_class.verify!(
          freeze_id: "pilot-rc-1", event_name: "push", event_path: nil
        )).to include("non-PR CI is allowed")
      end
    end
  end

  describe HafaPass::ReleaseCandidate::CandidateId do
    it "accepts stable lowercase identifiers and rejects unsafe paths" do
      expect(described_class.validate!("pilot-rc-2026-07-21.1")).to eq("pilot-rc-2026-07-21.1")
      expect { described_class.validate!("../candidate") }
        .to raise_error(HafaPass::ReleaseCandidate::Error, /Candidate ID/)
    end
  end

  describe HafaPass::ReleaseCandidate::SchemaVersion do
    it "extracts the canonical Rails schema version" do
      Dir.mktmpdir do |directory|
        schema = File.join(directory, "schema.rb")
        File.write(schema, "ActiveRecord::Schema[8.1].define(version: 2026_07_21_130000) do\nend\n")

        expect(described_class.read(schema)).to eq("20260721130000")
      end
    end
  end

  describe HafaPass::ReleaseCandidate::CheckEvidence do
    it "requires a successful observation for every named check" do
      entries = [
        { "name" => "RSpec", "conclusion" => "failure" },
        { "name" => "RSpec", "conclusion" => "success" },
        { "name" => "Security", "conclusion" => "success" },
        { "name" => "Browser", "conclusion" => "skipped" }
      ]
      summary = described_class.summarize(entries, %w[RSpec Security Browser Review])

      expect(summary.dig("RSpec", "passed")).to be(true)
      expect(summary.dig("Browser", "passed")).to be(false)
      expect { described_class.assert_passed!(summary, "Candidate") }
        .to raise_error(HafaPass::ReleaseCandidate::Error, /Browser, Review/)
    end
  end

  describe HafaPass::ReleaseCandidate::GitHubEvidence do
    it "normalizes malformed pull-request JSON into a release-candidate error" do
      shell = instance_double(HafaPass::ReleaseCandidate::Shell)
      allow(shell).to receive(:capture!).and_return("not-json")

      expect do
        described_class.new(shell: shell).send(:pull_request, "Shimizu-Technology/HafaPass", 32)
      end.to raise_error(HafaPass::ReleaseCandidate::Error, /invalid JSON/)
    end
  end

  describe HafaPass::ReleaseCandidate::EvidenceWriter do
    it "writes private, non-overwritable evidence files" do
      manifest = {
        "candidate_id" => "pilot-rc-1",
        "created_at" => "2026-07-21T00:00:00Z",
        "source" => { "commit_sha" => "a" * 40 },
        "github" => { "source_pull_request" => { "number" => 32 } }
      }

      Dir.mktmpdir do |directory|
        paths = described_class.new(File.join(directory, "pilot-rc-1")).write!(manifest)

        expect(paths.map(&:basename).map(&:to_s)).to contain_exactly("candidate.json", "evidence-register.md")
        expect(File.stat(paths.first).mode & 0o777).to eq(0o600)
        expect { described_class.new(File.join(directory, "pilot-rc-1")).write!(manifest) }
          .to raise_error(HafaPass::ReleaseCandidate::Error, /Refusing to overwrite/)

        partial = File.join(directory, "partial")
        FileUtils.mkdir_p(partial)
        File.write(File.join(partial, "evidence-register.md"), "existing")
        expect { described_class.new(partial).write!(manifest) }
          .to raise_error(HafaPass::ReleaseCandidate::Error, /evidence-register/)
        expect(File.exist?(File.join(partial, "candidate.json"))).to be(false)
      end
    end
  end
end
