# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require_relative "../../../scripts/release_candidate"

RSpec.describe HafaPass::ReleaseCandidate::IndependentReviewEvidence do
  let(:sha) { "a" * 40 }
  let(:tree) { "b" * 40 }
  let(:shell) { instance_double(HafaPass::ReleaseCandidate::Shell) }
  let(:error) { HafaPass::ReleaseCandidate::Error }
  let(:clock) { -> { Time.utc(2026, 10, 11) } }
  let(:report) do
    {
      "id" => "scanner-review", "kind" => "independent_agent", "status" => "completed",
      "outcome" => "no_material_findings", "scope" => "changed_files", "reviewer_ids" => ["agent:/root/reviewer"],
      "completed_at" => "2026-10-10T12:00:00Z", "limitations" => ["Static review; hosted QA remains separate."],
      "findings" => [], "reviewed_sha" => sha, "reviewed_tree" => tree,
      "covered_files" => ["src/scanner.jsx"], "report_path" => "report.md",
      "report_sha256" => Digest::SHA256.hexdigest("Completed exact scanner review; no material findings.\n")
    }
  end
  let(:bundle) do
    {
      "format_version" => 1, "repository" => "owner/repo", "source_pr" => 61, "head_sha" => sha, "head_tree" => tree,
      "outcome" => "no_unresolved_material_findings", "reviews" => [report],
      "authorization" => {
        "operator_login" => "operator", "approved_at" => "2026-10-10T13:00:00Z",
        "reference" => "conversation/user-independent-review-authorization",
        "statement" => described_class::ACKNOWLEDGEMENT
      }
    }
  end

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = Pathname(directory)
      @directory.join("report.md").write("Completed exact scanner review; no material findings.\n")
      example.run
    end
  end

  before do
    allow(shell).to receive(:capture!) do |*command, **_options|
      case command
      when ["gh", "api", "user"] then JSON.generate({ login: "operator" })
      when ["gh", "api", "repos/owner/repo/collaborators/operator/permission"] then JSON.generate({ permission: "maintain", role_name: "maintain" })
      else
        case command[1]
        when "rev-parse" then tree
        when "merge-base" then ""
        when "ls-tree" then "100644 blob #{'c' * 40}\tsrc/scanner.jsx\0"
        else raise "Unexpected command #{command}"
        end
      end
    end
  end

  def verify(acknowledged: true, files: ["src/scanner.jsx"])
    path = @directory.join("bundle.json")
    path.write(JSON.generate(bundle))
    described_class.new(root: @directory, shell: shell, clock: clock).verify!(
      path: path, acknowledged: acknowledged, repository: "owner/repo", number: 61, sha: sha, changed_files: files
    )
  end

  it "retains actual reviewer, source/report bindings, limitations and private archive bytes" do
    result = verify
    expect(result).to include("provider" => "independent", "head_sha" => sha, "head_tree" => tree)
    expect(result.fetch("reports").first).to include(
      "reviewed_sha" => sha, "source_head_sha" => sha, "reviewer_ids" => ["agent:/root/reviewer"],
      "file_blobs" => { "src/scanner.jsx" => "100644 blob #{'c' * 40}" },
      "report_path" => "reviews/scanner-review.md", "report_bytes" => include("Completed exact scanner review")
    )
  end

  it "requires explicit authorization, matching authenticated maintainer and reference" do
    expect { verify(acknowledged: false) }.to raise_error(error, /accept-independent-review/)
    bundle["authorization"]["operator_login"] = "someone-else"
    expect { verify }.to raise_error(error, /authenticated GitHub identity/)
    bundle["authorization"]["operator_login"] = "operator"
    bundle["authorization"]["reference"] = ""
    expect { verify }.to raise_error(error, /authorization reference/)
    bundle["authorization"]["reference"] = "user-instruction"
    allow(shell).to receive(:capture!).with("gh", "api", "repos/owner/repo/collaborators/operator/permission")
      .and_return(JSON.generate({ permission: "write", role_name: "write" }))
    expect { verify }.to raise_error(error, /repository maintainer/)
  end

  it "rejects stale repository, PR, head or tree and future timestamps" do
    %w[repository source_pr head_sha head_tree].each do |field|
      original = bundle[field]
      bundle[field] = "stale"
      expect { verify }.to raise_error(error)
      bundle[field] = original
    end
    report["completed_at"] = "2099-01-01T00:00:00Z"
    expect { verify }.to raise_error(error, /future/)
  end

  it "requires operator attestation after review completion and a nonempty UTF-8 report" do
    bundle["authorization"]["approved_at"] = "2026-10-10T11:00:00Z"
    expect { verify }.to raise_error(error, /follow completion/)
    bundle["authorization"]["approved_at"] = "2026-10-10T13:00:00Z"
    @directory.join("report.md").binwrite("\xff".b)
    expect { verify }.to raise_error(error, /UTF-8/)
  end

  it "rejects absent, partial, duplicate and extra coverage" do
    expect { verify(files: ["src/scanner.jsx", "src/checkout.jsx"]) }.to raise_error(error, /partial/)
    expect { verify(files: []) }.to raise_error(error, /coverage/)
    expect { verify(files: ["src/checkout.jsx"]) }.to raise_error(error, /partial/)
    bundle["reviews"] << report.dup
    expect { verify }.to raise_error(error, /unique/)
  end

  it "rejects tampering, escaping or unsupported report paths" do
    @directory.join("report.md").write("Changed after review")
    expect { verify }.to raise_error(error, /digest/)
    report["report_path"] = "/etc/hosts"
    expect { verify }.to raise_error(error, /contained/)
    report["report_path"] = "secrets.env"
    @directory.join("secrets.env").write("dummy")
    expect { verify }.to raise_error(error, /text format/)
  end

  it "reuses ancestor review only when every file mode/type/blob remains unchanged" do
    report["reviewed_sha"] = "d" * 40
    expect(verify.fetch("reports").first.fetch("reviewed_sha")).to eq("d" * 40)
    expect(shell).to have_received(:capture!).with("git", "merge-base", "--is-ancestor", "d" * 40, sha, chdir: @directory.to_s)
    allow(shell).to receive(:capture!).with("git", "ls-tree", "-z", sha, "--", "src/scanner.jsx", chdir: @directory.to_s)
      .and_return("100755 blob #{'c' * 40}\tsrc/scanner.jsx\0")
    expect { verify }.to raise_error(error, /stale/)
    allow(shell).to receive(:capture!).with("git", "merge-base", "--is-ancestor", "d" * 40, sha, chdir: @directory.to_s)
      .and_raise(error, "Not an ancestor")
    expect { verify }.to raise_error(error, /ancestor/)
  end

  it "never defaults missing completion, reviewer, limitations or findings to passed" do
    %w[status outcome reviewer_ids limitations findings].each do |field|
      original = report.delete(field)
      expect { verify }.to raise_error(error)
      report[field] = original
    end
    report["findings"] = [{ "severity" => "material", "status" => "open", "reference" => "finding-1", "disposition" => "Pending" }]
    expect { verify }.to raise_error(error, /Unresolved/)
    report["findings"][0]["status"] = "resolved"
    expect { verify }.to raise_error(error, /contradicts/)
    report["outcome"] = "material_findings_resolved"
    expect(verify.fetch("reports").first.fetch("findings").first.fetch("status")).to eq("resolved")
  end

  it "accepts actual completed CLI JSONL and rejects capacity, mismatched files or untriaged findings" do
    report["kind"] = "coderabbit_cli"
    completed = { type: "complete", status: "review_completed", findings: 0, reviewedFiles: ["src/scanner.jsx"] }
    write_cli = lambda do |payload|
      bytes = JSON.generate(payload) + "\n"
      @directory.join("report.md").write(bytes)
      report["report_sha256"] = Digest::SHA256.hexdigest(bytes)
    end
    write_cli.call(completed)
    expect(verify.fetch("reports").first.fetch("kind")).to eq("coderabbit_cli")
    [completed.merge(status: "rate_limited"), completed.merge(reviewedFiles: ["other.jsx"]), completed.merge(findings: 1)].each do |payload|
      write_cli.call(payload)
      expect { verify }.to raise_error(error, /actually complete/)
    end
  end
end
