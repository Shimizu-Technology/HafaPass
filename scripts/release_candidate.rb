#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "time"

module HafaPass
  module ReleaseCandidate
    MAIN_CHECKS = [
      "Backend / RSpec",
      "Backend / Quality and security",
      "Frontend / Test, build, and security",
      "Browser / Service recovery smoke tests",
      "Repository / Secret and debug hygiene",
      "Release / Freeze contract"
    ].freeze
    CODERABBIT_CONTEXT = "CodeRabbit"
    CODERABBIT_APP_ID = 347564
    PR_CHECKS = (MAIN_CHECKS + [CODERABBIT_CONTEXT]).freeze
    CANDIDATE_PATTERN = /\A[a-z0-9][a-z0-9._-]{2,63}\z/

    class Error < StandardError; end

    require_relative "review_provenance"

    class Shell
      def capture!(*command, chdir: nil)
        stdout, stderr, status = Open3.capture3(*command, **spawn_options(chdir))
        return stdout if status.success?

        detail = stderr.strip.empty? ? stdout.strip : stderr.strip
        raise Error, "Command failed: #{command.join(' ')}#{detail.empty? ? '' : " (#{detail})"}"
      end

      def stream!(*command, chdir: nil)
        success = system(*command, **spawn_options(chdir))
        raise Error, "Command failed: #{command.join(' ')}" unless success
      end

      private

        def spawn_options(chdir)
          chdir ? { chdir: chdir } : {}
        end
    end

    module CandidateId
      module_function

      def validate!(value)
        return value if value&.match?(CANDIDATE_PATTERN)

        raise Error, "Candidate ID must be 3-64 lowercase letters, numbers, dots, underscores, or hyphens."
      end
    end

    module SchemaVersion
      module_function

      def read(path)
        match = File.read(path).match(/define\(version:\s*([0-9_]+)\)/)
        raise Error, "Could not determine the Rails schema version from #{path}." unless match

        match[1].delete("_")
      end
    end

    module CheckEvidence
      module_function

      def summarize(entries, required_names)
        grouped = entries.group_by { |entry| entry.fetch("name") }
        required_names.to_h do |name|
          matching = grouped.fetch(name, [])
          successful = matching.any? { |entry| success?(entry.fetch("conclusion", "")) }
          [name, { "passed" => successful, "observed" => matching.map { |entry| entry["conclusion"] }.uniq.sort }]
        end
      end

      def success?(value)
        value.to_s.casecmp?("success")
      end

      def assert_passed!(summary, scope)
        failures = summary.filter_map { |name, result| name unless result.fetch("passed") }
        return if failures.empty?

        raise Error, "#{scope} is missing successful required checks: #{failures.join(', ')}"
      end
    end

    module CodeRabbitEvidence
      module_function

      # CodeRabbit can publish success when it skips a review. A green status
      # alone is therefore insufficient: retain a submitted review on this head.
      def verify!(statuses:, reviews:, sha:)
        # Status contexts are not exclusive to their provider: repository writers
        # can publish the same name. Select the latest status from the actual bot.
        status = statuses.find do |entry|
          entry["context"] == CODERABBIT_CONTEXT && entry.dig("creator", "login") == "coderabbitai[bot]" &&
            entry.dig("creator", "type") == "Bot"
        end
        unless status && CheckEvidence.success?(status["state"]) &&
            status["description"].to_s.match?(/\breview completed\b/i) &&
            !status["description"].match?(/\breview (?:skipped|paused)\b/i)
          raise Error, "CodeRabbit must have a completed review status on the source pull-request head; skipped reviews do not qualify."
        end

        review = reviews.select do |entry|
          entry.dig("user", "login") == "coderabbitai[bot]" && entry.dig("user", "type") == "Bot" &&
            entry["commit_id"] == sha && entry["submitted_at"]
        end.max_by { |entry| [entry["submitted_at"], entry.fetch("id")] }
        unless review && %w[COMMENTED APPROVED].include?(review["state"]) &&
            (review["state"] == "APPROVED" || !review["body"].to_s.strip.empty?) &&
            !review["body"].match?(/(?:\A|\n)\s*(?:>\s*)?(?:\#+\s*)?Review (?:skipped|paused)\b/i)
          raise Error, "CodeRabbit must have a submitted, completed review on the source pull-request head."
        end

        {
          "provider" => CODERABBIT_CONTEXT,
          "head_sha" => sha,
          "status_description" => status.fetch("description"),
          "review_id" => review.fetch("id"),
          "review_url" => review.fetch("html_url"),
          "review_state" => review.fetch("state"),
          "submitted_at" => review.fetch("submitted_at")
        }
      end
    end

    class GitHubEvidence
      def initialize(shell: Shell.new)
        @shell = shell
      end

      def collect(repository:, sha:, source_pr_number:, independent_review: nil, accept_independent_review: false, root: Pathname(__dir__).parent)
        main_entries = main_check_entries(repository, sha)
        main_checks = CheckEvidence.summarize(main_entries, MAIN_CHECKS)
        CheckEvidence.assert_passed!(main_checks, "Candidate commit")

        pr = pull_request(repository, source_pr_number)
        raise Error, "Source pull request ##{source_pr_number} is not merged." unless pr.fetch("state") == "MERGED" && pr["mergedAt"]

        pr_entries = Array(pr.fetch("statusCheckRollup")).filter_map do |entry|
          name = entry["name"] || entry["context"]
          conclusion = entry["conclusion"] || entry["state"]
          { "name" => name, "conclusion" => conclusion } if name
        end
        pr_checks = CheckEvidence.summarize(pr_entries, PR_CHECKS)
        CheckEvidence.assert_passed!(pr_checks, "Source pull request")
        code_review = code_review_evidence(repository, source_pr_number, pr.fetch("headRefOid"),
          independent_review: independent_review, acknowledged: accept_independent_review, root: root)

        unresolved_threads = unresolved_review_threads(repository, source_pr_number)
        raise Error, "Source pull request has #{unresolved_threads} unresolved review thread(s)." if unresolved_threads.positive?

        blockers = open_priority_issues(repository)
        raise Error, "Open P0/P1 issues block the candidate: #{blockers.map { |issue| "##{issue['number']}" }.join(', ')}" if blockers.any?

        protection = branch_protection(repository)
        validate_protection!(protection)

        {
          "main_checks" => main_checks,
          "source_pull_request" => {
            "number" => pr.fetch("number"),
            "url" => pr.fetch("url"),
            "head_sha" => pr.fetch("headRefOid"),
            "merged_at" => pr.fetch("mergedAt"),
            "checks" => pr_checks,
            "code_review" => code_review,
            "unresolved_review_threads" => unresolved_threads
          },
          "open_p0_p1_issues" => blockers,
          "branch_protection" => {
            "enabled" => true,
            "strict_status_checks" => protection.dig("required_status_checks", "strict") == true,
            "required_checks" => Array(protection.dig("required_status_checks", "contexts")).sort,
            "review_check_app_id" => CODERABBIT_APP_ID,
            "pull_request_required" => !protection["required_pull_request_reviews"].nil?,
            "administrators_enforced" => protection.dig("enforce_admins", "enabled") == true,
            "conversation_resolution_required" => protection.dig("required_conversation_resolution", "enabled") == true,
            "force_pushes_allowed" => protection.dig("allow_force_pushes", "enabled") == true,
            "deletions_allowed" => protection.dig("allow_deletions", "enabled") == true
          }
        }
      end

      private

        def json!(*command)
          JSON.parse(@shell.capture!(*command))
        rescue JSON::ParserError => e
          raise Error, "GitHub returned invalid JSON: #{e.message}"
        end

        def main_check_entries(repository, sha)
          payload = json!(
            "gh", "api", "--method", "GET", "repos/#{repository}/commits/#{sha}/check-runs", "-f", "per_page=100"
          )
          Array(payload.fetch("check_runs")).map do |entry|
            { "name" => entry.fetch("name"), "conclusion" => entry["conclusion"] }
          end
        end

        def pull_request(repository, number)
          json!(
            "gh", "pr", "view", number.to_s,
            "--repo", repository,
            "--json", "number,url,state,mergedAt,headRefOid,statusCheckRollup"
          )
        end

        def code_review_evidence(repository, number, sha, independent_review: nil, acknowledged: false, root: Pathname(__dir__).parent)
          statuses = json!(
            "gh", "api", "--paginate", "--slurp", "repos/#{repository}/commits/#{sha}/statuses?per_page=100"
          ).flatten
          reviews = json!(
            "gh", "api", "--paginate", "--slurp", "repos/#{repository}/pulls/#{number}/reviews?per_page=100"
          ).flatten
          if independent_review
            files = json!("gh", "api", "--paginate", "--slurp", "repos/#{repository}/pulls/#{number}/files?per_page=100").flatten
              .map { |file| file.fetch("filename") }
            evidence = IndependentReviewEvidence.new(root: root, shell: @shell).verify!(
              path: independent_review, acknowledged: acknowledged, repository: repository, number: number, sha: sha, changed_files: files
            )
            evidence.merge("observed_github_review" => { "statuses" => statuses, "reviews" => reviews })
          else
            raise Error, "--accept-independent-review requires --independent-review-evidence." if acknowledged

            CodeRabbitEvidence.verify!(statuses: statuses, reviews: reviews, sha: sha)
          end
        end

        def unresolved_review_threads(repository, number)
          owner, name = repository.split("/", 2)
          query = <<~GRAPHQL
          query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
            repository(owner: $owner, name: $name) {
              pullRequest(number: $number) {
                reviewThreads(first: 100, after: $cursor) {
                  nodes { isResolved }
                  pageInfo { hasNextPage endCursor }
                }
              }
            }
          }
        GRAPHQL
          unresolved = 0
          cursor = nil
          loop do
            command = [
              "gh", "api", "graphql", "-f", "query=#{query}", "-f", "owner=#{owner}",
              "-f", "name=#{name}", "-F", "number=#{number}"
            ]
            command += ["-f", "cursor=#{cursor}"] if cursor
            connection = json!(*command).dig("data", "repository", "pullRequest", "reviewThreads")
            unless connection && connection["nodes"].is_a?(Array) &&
                [true, false].include?(connection.dig("pageInfo", "hasNextPage"))
              raise Error, "GitHub review-thread evidence could not be verified."
            end
            unresolved += connection.fetch("nodes").count { |thread| thread["isResolved"] != true }
            break unless connection.dig("pageInfo", "hasNextPage")

            next_cursor = connection.dig("pageInfo", "endCursor")
            raise Error, "GitHub review-thread pagination could not be verified." if next_cursor.nil? || next_cursor == cursor

            cursor = next_cursor
          end
          unresolved
        end

        def open_priority_issues(repository)
          issues = JSON.parse(@shell.capture!(
            "gh", "issue", "list", "--repo", repository, "--state", "open", "--limit", "100",
            "--json", "number,title,labels,url"
          ))
          issues.select do |issue|
            labels = Array(issue["labels"]).map { |label| label.fetch("name").downcase }
            labels.any? { |label| label.match?(/\A(?:priority[: -]?)?p[01]\z/) } ||
              issue.fetch("title").match?(/\A\s*\[P[01]\]/i)
          end
        end

        def branch_protection(repository)
          json!("gh", "api", "repos/#{repository}/branches/main/protection")
        rescue Error => e
          raise Error, "The main branch is not protected or protection could not be verified: #{e.message}"
        end

        def validate_protection!(protection)
          contexts = Array(protection.dig("required_status_checks", "contexts"))
          missing = PR_CHECKS - contexts
          raise Error, "Main branch protection is missing required checks: #{missing.join(', ')}" if missing.any?
          review_check = Array(protection.dig("required_status_checks", "checks")).find do |check|
            check["context"] == CODERABBIT_CONTEXT
          end
          unless review_check && review_check["app_id"] == CODERABBIT_APP_ID
            raise Error, "Main branch protection must bind CodeRabbit to its GitHub App (#{CODERABBIT_APP_ID})."
          end
          raise Error, "Main branch protection must require branches to be current." unless protection.dig("required_status_checks", "strict") == true
          raise Error, "Main branch protection must require pull requests." if protection["required_pull_request_reviews"].nil?
          raise Error, "Main branch protection must include administrators." unless protection.dig("enforce_admins", "enabled") == true
          unless protection.dig("required_conversation_resolution", "enabled") == true
            raise Error, "Main branch protection must require conversation resolution."
          end
          raise Error, "Main branch protection must prohibit force pushes." if protection.dig("allow_force_pushes", "enabled") == true
          raise Error, "Main branch protection must prohibit deletion." if protection.dig("allow_deletions", "enabled") == true
        end
    end

    class EvidenceWriter
      def initialize(output_dir)
        @output_dir = Pathname(output_dir)
      end

      def write!(manifest)
        FileUtils.mkdir_p(@output_dir, mode: 0o700)
        json_path = @output_dir.join("candidate.json")
        register_path = @output_dir.join("evidence-register.md")
        existing = [json_path, register_path].select(&:exist?)
        if existing.any?
          raise Error,
            "Refusing to overwrite existing evidence file(s): #{existing.join(', ')}. " \
            "Choose a new candidate ID or archive them first."
        end

        manifest = Marshal.load(Marshal.dump(manifest))
        reports = manifest.dig("github", "source_pull_request", "code_review", "reports") || []
        reports.each do |report|
          bytes = report.delete("report_bytes")
          raise Error, "Verified report bytes are required." unless bytes && Digest::SHA256.hexdigest(bytes) == report["report_sha256"]

          report_path = @output_dir.join(report.fetch("report_path"))
          FileUtils.mkdir_p(report_path.dirname, mode: 0o700)
          write_private!(report_path, bytes)
        end
        write_private!(json_path, JSON.pretty_generate(manifest) + "\n")
        write_private!(register_path, register(manifest))
        [json_path, register_path]
      end

      private

        def write_private!(path, contents)
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(contents) }
        rescue Errno::EEXIST
          raise Error, "Refusing to overwrite existing evidence file #{path}. Choose a new candidate ID or archive it first."
        end

        def register(manifest)
          id = manifest.fetch("candidate_id")
          sha = manifest.dig("source", "commit_sha")
          <<~MARKDOWN
          # HafaPass private release evidence register

          Candidate: `#{id}`  
          Commit: `#{sha}`  
          Created: #{manifest.fetch("created_at")}

          This directory is intentionally gitignored. Record references and redacted evidence only—never secrets, full payment data, unnecessary PII, or raw identity documents.

          | Gate/control | Owner | Due date | Test/evidence ID | Status | Approval/reference | Exceptions/issues |
          |---|---|---|---|---|---|---|
          | A — candidate contract | Engineering lead / founder | TBD | `#{id}-A` | automated evidence captured; approvals pending | PR ##{manifest.dig("github", "source_pull_request", "number")} | None recorded |
          | B — Guam business and money decision | Founder / counsel / accountant / provider | TBD | `#{id}-B` | pending | | |
          | C — production environment and restore | Engineering / operations / independent verifier | TBD | `#{id}-C` | pending | | |
          | D — provider and policy evidence | Engineering / legal / accounting / privacy | TBD | `#{id}-D` | pending | | |
          | E — first pilot selection | Founder / organizer success / venue / finance | TBD | `#{id}-E` | pending | | |
          | F — buyer, organizer, accessibility, and load QA | QA / representative users / venue | TBD | `#{id}-F` | pending | | |
          | G — event-day rehearsal | Event commander / technical lead | TBD | `#{id}-G` | pending | | |
          | H — live low-value money loop | Finance lead / independent approver | TBD | `#{id}-H` | pending | | |
          | I — bounded live-pilot operation | Incident commander / business owner | TBD | `#{id}-I` | pending | | |
          | J — closeout and expansion decision | Finance / operations / organizer success / engineering | TBD | `#{id}-J` | pending | | |

          ## Gate A human approvals

          - [ ] Engineering lead confirms this exact commit and schema are the candidate.
          - [ ] Founder approves the release freeze and scope.
          - [ ] Named owner and backup are recorded for every Gate B–J row.
          - [ ] Due dates are recorded for every Gate B–J row.
          - [ ] No exception is accepted without an owner, expiry, risk statement, and issue/reference.
        MARKDOWN
        end
    end

    class Capture
      def initialize(root:, shell: Shell.new, github: nil, clock: -> { Time.now.utc })
        @root = Pathname(root)
        @shell = shell
        @github = github || GitHubEvidence.new(shell: shell)
        @clock = clock
      end

      def call(candidate_id:, output_base: ".release-evidence", independent_review: nil, accept_independent_review: false)
        CandidateId.validate!(candidate_id)
        assert_candidate_worktree!

        sha = git("rev-parse", "HEAD").strip
        origin_sha = git("rev-parse", "origin/main").strip
        raise Error, "HEAD must exactly match origin/main before capture." unless sha == origin_sha

        source_pr_number = source_pr_number!
        repository = JSON.parse(@shell.capture!("gh", "repo", "view", "--json", "nameWithOwner")).fetch("nameWithOwner")

        @shell.stream!(@root.join("scripts/gate.sh").to_s, chdir: @root.to_s)
        gate_completed_at = @clock.call.iso8601
        github = @github.collect(repository: repository, sha: sha, source_pr_number: source_pr_number,
          independent_review: independent_review, accept_independent_review: accept_independent_review, root: @root)

        manifest = build_manifest(candidate_id, repository, sha, github, gate_completed_at)
        output_dir = @root.join(output_base, candidate_id)
        paths = EvidenceWriter.new(output_dir).write!(manifest)

        { manifest: manifest, paths: paths }
      end

      private

        def git(*arguments)
          @shell.capture!("git", *arguments, chdir: @root.to_s)
        end

        def assert_candidate_worktree!
          branch = git("branch", "--show-current").strip
          raise Error, "Release evidence must be captured from main, not #{branch.inspect}." unless branch == "main"

          tracked_changes = git("status", "--porcelain", "--untracked-files=no")
          raise Error, "Tracked worktree changes must be committed before capture." unless tracked_changes.strip.empty?

          git("fetch", "origin", "main", "--quiet")
        end

        def source_pr_number!
          subject = git("show", "-s", "--format=%s", "HEAD").strip
          match = subject.match(/Merge pull request #(\d+)/)
          raise Error, "Candidate HEAD must be a GitHub pull-request merge commit." unless match

          match[1].to_i
        end

        def build_manifest(candidate_id, repository, sha, github, gate_completed_at)
          created_at = @clock.call.iso8601
          schema_path = @root.join("hafapass_api/db/schema.rb")
          gem_lock = @root.join("hafapass_api/Gemfile.lock")
          npm_lock = @root.join("hafapass_frontend/package-lock.json")
          short_sha = sha[0, 12]

          {
            "format_version" => 1,
            "candidate_id" => candidate_id,
            "created_at" => created_at,
            "source" => {
              "repository" => repository,
              "branch" => "main",
              "commit_sha" => sha,
              "commit_subject" => git("show", "-s", "--format=%s", sha).strip,
              "committed_at" => git("show", "-s", "--format=%cI", sha).strip
            },
            "release_ids" => {
              "backend" => "hafapass-api-git-#{short_sha}",
              "frontend" => "hafapass-web-git-#{short_sha}"
            },
            "database" => {
              "schema_version" => SchemaVersion.read(schema_path),
              "schema_sha256" => Digest::SHA256.file(schema_path).hexdigest
            },
            "dependency_locks" => {
              "ruby_sha256" => Digest::SHA256.file(gem_lock).hexdigest,
              "npm_sha256" => Digest::SHA256.file(npm_lock).hexdigest
            },
            "local_gate" => {
              "command" => "./scripts/gate.sh",
              "passed" => true,
              "completed_at" => gate_completed_at
            },
            "github" => github,
            "human_approvals" => {
              "engineering_lead" => "pending",
              "founder" => "pending"
            },
            "exceptions" => []
          }
        end
    end

    class CLI
      def self.run(argv)
        options = { output_base: ".release-evidence" }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: scripts/release_candidate.rb --candidate ID [--output-base PATH]"
          opts.on("--candidate ID", "Stable candidate ID, for example pilot-rc-2026-07-21.1") { |value| options[:candidate_id] = value }
          opts.on("--output-base PATH", "Private output base (default: .release-evidence)") { |value| options[:output_base] = value }
          opts.on("--independent-review-evidence PATH", "Private completed independent/CLI review bundle") { |value| options[:independent_review] = value }
          opts.on("--accept-independent-review", "Attest the user's explicit independent-review authorization") { options[:accept_independent_review] = true }
          opts.on("-h", "--help", "Show this help") { puts opts; return 0 }
        end
        parser.parse!(argv)
        raise Error, "--candidate is required." unless options[:candidate_id]

        root = Pathname(__dir__).parent
        result = Capture.new(root: root).call(**options)
        puts "Candidate #{result[:manifest].fetch('candidate_id')} passed automated Gate A capture."
        result[:paths].each { |path| puts "Wrote private evidence: #{path.relative_path_from(root)}" }
        puts "Complete the human approvals, then create and push the matching annotated git tag."
        0
      rescue OptionParser::ParseError, Error => e
        warn e.message
        1
      end
    end
  end
end

exit HafaPass::ReleaseCandidate::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
