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
        expect do
          described_class.new.stream!(
            "ruby", "-e", "exit(Dir.pwd == ARGV.fetch(0) ? 0 : 1)", File.realpath(directory), chdir: directory
          )
        end.not_to raise_error
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

  describe HafaPass::ReleaseCandidate::CodeRabbitEvidence do
    let(:sha) { "a" * 40 }
    let(:status) do
      {
        "context" => "CodeRabbit", "state" => "success", "description" => "Review completed",
        "creator" => { "login" => "coderabbitai[bot]", "type" => "Bot" }
      }
    end
    let(:review) do
      {
        "id" => 123, "html_url" => "https://github.com/owner/repo/pull/1#pullrequestreview-123",
        "user" => { "login" => "coderabbitai[bot]", "type" => "Bot" },
        "commit_id" => sha, "submitted_at" => "2026-10-09T12:00:00Z", "state" => "COMMENTED",
        "body" => "**Actionable comments posted: 0**"
      }
    end

    def verify(statuses: [status], reviews: [review])
      described_class.verify!(statuses: statuses, reviews: reviews, sha: sha)
    end

    it "retains a completed bot review for the exact head" do
      expect(verify).to include("head_sha" => sha, "review_id" => 123, "review_state" => "COMMENTED")
    end

    it "rejects success statuses that skipped, paused, or never completed review" do
      ["Review skipped: 142 files exceed the limit of 100", "Review paused", "Review in progress",
       "Review completed; review skipped", ""].each do |description|
        expect { verify(statuses: [status.merge("description" => description)]) }
          .to raise_error(HafaPass::ReleaseCandidate::Error, /completed review status/)
      end
    end

    it "rejects missing, failed, or superseded status even when an older run succeeded" do
      expect { verify(statuses: []) }.to raise_error(HafaPass::ReleaseCandidate::Error)
      expect { verify(statuses: [status.merge("state" => "pending"), status]) }
        .to raise_error(HafaPass::ReleaseCandidate::Error)
    end

    it "ignores newer same-context statuses from another issuer and requires actual bot evidence" do
      fake_status = status.merge("creator" => { "login" => "repository-writer", "type" => "User" })
      expect(verify(statuses: [fake_status, status])).to include("status_description" => "Review completed")
      expect { verify(statuses: [fake_status]) }
        .to raise_error(HafaPass::ReleaseCandidate::Error, /completed review status/)
      expect { verify(statuses: [status.merge("creator" => nil)]) }
        .to raise_error(HafaPass::ReleaseCandidate::Error, /completed review status/)
      expect { verify(statuses: [status.merge("creator" => { "login" => "coderabbitai[bot]", "type" => "User" })]) }
        .to raise_error(HafaPass::ReleaseCandidate::Error, /completed review status/)
    end

    it "cannot conceal a later skipped bot review with a newer forged completed status" do
      fake_status = status.merge("creator" => { "login" => "repository-writer", "type" => "User" })
      skipped_status = status.merge("description" => "Review skipped: file limit exceeded")
      expect { verify(statuses: [fake_status, skipped_status, status]) }
        .to raise_error(HafaPass::ReleaseCandidate::Error, /skipped reviews do not qualify/)
    end

    it "rejects absent, stale, impersonated, empty, pending, or dismissed reviews" do
      invalid_reviews = [
        [], [review.merge("commit_id" => "b" * 40)],
        [review.merge("user" => { "login" => "coderabbitai[bot]", "type" => "User" })],
        [review.merge("user" => { "login" => "someone-else[bot]", "type" => "Bot" })],
        [review.merge("body" => "")], [review.merge("submitted_at" => nil)],
        [review.merge("state" => "PENDING")], [review.merge("state" => "DISMISSED")],
        [review.merge("body" => "> ## Review skipped\nToo many files!")]
      ]
      invalid_reviews.each do |reviews|
        expect { verify(reviews: reviews) }.to raise_error(HafaPass::ReleaseCandidate::Error, /submitted, completed review/)
      end
    end

    it "does not hide a newer request for changes behind an earlier approval" do
      newer_review = review.merge("id" => 124, "submitted_at" => "2026-10-09T12:01:00Z", "state" => "CHANGES_REQUESTED")
      expect { verify(reviews: [review.merge("state" => "APPROVED"), newer_review]) }
        .to raise_error(HafaPass::ReleaseCandidate::Error, /submitted, completed review/)
    end
  end

  describe HafaPass::ReleaseCandidate::GitHubEvidence do
    let(:protection) do
      {
        "required_status_checks" => {
          "strict" => true, "contexts" => HafaPass::ReleaseCandidate::PR_CHECKS,
          "checks" => [{ "context" => "CodeRabbit", "app_id" => 347564 }]
        },
        "required_pull_request_reviews" => {}, "enforce_admins" => { "enabled" => true },
        "required_conversation_resolution" => { "enabled" => true }
      }
    end

    it "requires the CodeRabbit check to be bound to the installed GitHub App" do
      evidence = described_class.new
      expect { evidence.send(:validate_protection!, protection) }.not_to raise_error
      [nil, -1, 15368].each do |app_id|
        protection["required_status_checks"]["checks"][0]["app_id"] = app_id
        expect { evidence.send(:validate_protection!, protection) }
          .to raise_error(HafaPass::ReleaseCandidate::Error, /bind CodeRabbit/)
      end
    end

    it "rejects the obsolete reviewer contract even when all engineering checks are present" do
      protection["required_status_checks"]["contexts"] = HafaPass::ReleaseCandidate::MAIN_CHECKS + ["Greptile Review"]
      expect { described_class.new.send(:validate_protection!, protection) }
        .to raise_error(HafaPass::ReleaseCandidate::Error, /missing required checks: CodeRabbit/)
    end

    it "captures the actual paginated status and review payloads alongside engineering checks" do
      shell = instance_double(HafaPass::ReleaseCandidate::Shell)
      sha = "a" * 40
      pr = {
        "number" => 57, "url" => "https://github.com/owner/repo/pull/57", "headRefOid" => sha,
        "state" => "MERGED", "mergedAt" => "2026-10-09T12:30:00Z",
        "statusCheckRollup" => HafaPass::ReleaseCandidate::PR_CHECKS.map { |name| { "name" => name, "conclusion" => "success" } }
      }
      status = {
        "context" => "CodeRabbit", "state" => "success", "description" => "Review completed",
        "creator" => { "login" => "coderabbitai[bot]", "type" => "Bot" }
      }
      review = {
        "id" => 123, "html_url" => "https://github.com/owner/repo/pull/57#pullrequestreview-123",
        "user" => { "login" => "coderabbitai[bot]", "type" => "Bot" }, "commit_id" => sha,
        "state" => "COMMENTED", "body" => "**Actionable comments posted: 0**", "submitted_at" => "2026-10-09T12:00:00Z"
      }
      allow(shell).to receive(:capture!) do |*command|
        payload = case command.join(" ")
        when /check-runs/
          { "check_runs" => HafaPass::ReleaseCandidate::MAIN_CHECKS.map { |name| { "name" => name, "conclusion" => "success" } } }
        when /pr view/ then pr
        when /statuses\?per_page/ then [[status]]
        when /reviews\?per_page/ then [[review]]
        when /graphql/
          { "data" => { "repository" => { "pullRequest" => { "reviewThreads" => {
            "nodes" => [], "pageInfo" => { "hasNextPage" => false }
          } } } } }
        when /issue list/ then []
        when /branches\/main\/protection/ then protection
        else raise "Unexpected command: #{command}"
        end
        JSON.generate(payload)
      end
      evidence = described_class.new(shell: shell)
      expect(evidence.collect(repository: "owner/repo", sha: "b" * 40, source_pr_number: 57))
        .to include("source_pull_request" => include("code_review" => include("head_sha" => sha, "review_id" => 123)))

      status["description"] = "Review skipped: 142 files exceed the limit of 100"
      expect { evidence.collect(repository: "owner/repo", sha: "b" * 40, source_pr_number: 57) }
        .to raise_error(HafaPass::ReleaseCandidate::Error, /skipped reviews do not qualify/)
    end

    it "counts unresolved threads beyond the first page and rejects missing thread evidence" do
      shell = instance_double(HafaPass::ReleaseCandidate::Shell)
      payload = ->(nodes, has_next, cursor = nil) do
        JSON.generate({ "data" => { "repository" => { "pullRequest" => { "reviewThreads" => {
          "nodes" => nodes, "pageInfo" => { "hasNextPage" => has_next, "endCursor" => cursor }
        } } } } })
      end
      allow(shell).to receive(:capture!).and_return(
        payload.call(Array.new(100) { { "isResolved" => true } }, true, "page-1"),
        payload.call([{ "isResolved" => false }], false)
      )
      expect(described_class.new(shell: shell).send(:unresolved_review_threads, "owner/repo", 57)).to eq(1)
      expect(shell).to have_received(:capture!).with(any_args, "cursor=page-1")
      allow(shell).to receive(:capture!).and_return(JSON.generate({ "errors" => [{ "message" => "Unavailable" }] }))
      expect { described_class.new(shell: shell).send(:unresolved_review_threads, "owner/repo", 57) }
        .to raise_error(HafaPass::ReleaseCandidate::Error, /could not be verified/)
    end

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
        register = File.read(paths.find { |path| path.basename.to_s == "evidence-register.md" })
        expect(register).to include(
          "I — bounded live-pilot operation", "J — closeout and expansion decision", "Gate B–J row"
        )
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
