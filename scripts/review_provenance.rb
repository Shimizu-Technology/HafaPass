# frozen_string_literal: true

module HafaPass
  module ReleaseCandidate
    # The authenticated operator attests authorship and review truth. This validator
    # verifies the source/report bindings; it cannot manufacture that attestation.
    class IndependentReviewEvidence
      ACKNOWLEDGEMENT = "I accept these reviews under the user's independent-review authorization."
      OUTCOMES = %w[no_material_findings nonblocking_findings material_findings_resolved].freeze
      REPORT_EXTENSIONS = %w[.md .txt .log .json .jsonl].freeze

      def initialize(root:, shell:, clock: -> { Time.now.utc })
        @root = Pathname(root)
        @shell = shell
        @clock = clock
      end

      def verify!(path:, acknowledged:, repository:, number:, sha:, changed_files:)
        raise Error, "Independent review requires --accept-independent-review." unless acknowledged

        bundle_path = Pathname(path).realpath
        bundle_bytes = bundle_path.binread
        bundle = JSON.parse(bundle_bytes)
        assert!(bundle.is_a?(Hash), "Independent review bundle must be an object.")
        assert!(bundle["format_version"] == 1, "Unsupported independent review format.")
        assert!(bundle["repository"] == repository && bundle["source_pr"] == number && bundle["head_sha"] == sha,
          "Independent review must match the exact repository, source PR and head.")
        tree = git("rev-parse", "#{sha}^{tree}").strip
        assert!(bundle["head_tree"] == tree, "Independent review head tree is stale.")
        authorization = verify_operator!(bundle["authorization"], repository)
        assert!(bundle["outcome"] == "no_unresolved_material_findings", "Independent review outcome is not complete.")
        records = bundle["reviews"]
        assert!(records.is_a?(Array) && records.any?, "Independent review reports are required.")
        assert!(changed_files.is_a?(Array) && changed_files.any?, "Source PR file coverage could not be verified.")
        reports = records.map { |record| verify_report!(record, bundle_path.dirname, sha, tree) }
        assert!(reports.all? { |report| Time.iso8601(report.fetch("completed_at")) <= Time.iso8601(authorization.fetch("approved_at")) },
          "Operator approval must follow completion of every review.")
        ids = reports.map { |report| report.fetch("id") }
        assert!(ids.uniq == ids, "Independent review IDs must be unique.")
        covered = reports.flat_map { |report| report.fetch("covered_files") }.uniq
        missing = changed_files - covered
        assert!(missing.empty?, "Independent review is partial; missing files: #{missing.join(', ')}")
        extra = covered - changed_files
        assert!(extra.empty?, "Independent review coverage contains files outside the source PR.")
        {
          "provider" => "independent", "head_sha" => sha, "head_tree" => tree,
          "bundle_sha256" => Digest::SHA256.hexdigest(bundle_bytes),
          "authorization" => authorization, "outcome" => bundle.fetch("outcome"),
          "covered_files" => covered.sort, "reports" => reports
        }
      rescue JSON::ParserError, KeyError, Errno::ENOENT, Errno::EACCES, ArgumentError, TypeError => e
        raise Error, "Independent review evidence is invalid: #{e.message}"
      end

      private

        def assert!(condition, message)
          raise Error, message unless condition
        end

        def text?(value)
          value.is_a?(String) && !value.strip.empty?
        end

        def timestamp!(value)
          assert!(text?(value), "Review timestamps are required.")
          time = Time.iso8601(value)
          assert!(time <= @clock.call, "Review timestamps cannot be in the future.")
          time
        end

        def verify_operator!(authorization, repository)
          assert!(authorization.is_a?(Hash), "Explicit operator authorization is required.")
          actor = json!("gh", "api", "user").fetch("login")
          permission = json!("gh", "api", "repos/#{repository}/collaborators/#{actor}/permission")
          assert!(%w[admin maintain].include?(permission["permission"]) || %w[admin maintain].include?(permission["role_name"]),
            "Independent review must be attested by an authenticated repository maintainer.")
          assert!(authorization["operator_login"] == actor, "Independent review operator does not match authenticated GitHub identity.")
          assert!(authorization["statement"] == ACKNOWLEDGEMENT && text?(authorization["reference"]),
            "Independent review needs the explicit user-authorization reference and acknowledgement.")
          timestamp!(authorization["approved_at"])
          authorization.merge("verified_permission" => permission["role_name"] || permission["permission"])
        end

        def verify_report!(record, directory, head, tree)
          assert!(record.is_a?(Hash), "Review records must be objects.")
          id = record["id"]
          assert!(id.is_a?(String) && id.match?(/\A[a-z0-9][a-z0-9_-]{0,63}\z/), "Review ID is invalid.")
          assert!(%w[independent_agent coderabbit_cli].include?(record["kind"]) && record["status"] == "completed" &&
            OUTCOMES.include?(record["outcome"]) && record["scope"] == "changed_files", "Review kind, completion, outcome and scope must be explicit.")
          reviewers = record["reviewer_ids"]
          assert!(reviewers.is_a?(Array) && reviewers.any? && reviewers.all? { |reviewer| text?(reviewer) } &&
            reviewers.uniq == reviewers, "Actual review identities are required.")
          timestamp!(record["completed_at"])
          assert!(record["limitations"].is_a?(Array) && record["limitations"].all? { |item| text?(item) }, "Review limitations must be explicit.")
          verify_findings!(record)
          reviewed = record["reviewed_sha"]
          assert!(reviewed.is_a?(String) && reviewed.match?(/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/), "Reviewed commit must be a full digest.")
          reviewed_tree = git("rev-parse", "#{reviewed}^{tree}").strip
          assert!(record["reviewed_tree"] == reviewed_tree, "Reviewed tree does not match the reviewed commit.")
          git("merge-base", "--is-ancestor", reviewed, head) unless reviewed == head
          files = record["covered_files"]
          assert!(files.is_a?(Array) && files.any? && files.uniq == files && files.all? { |file| safe_git_path?(file) },
            "Reviewed file scope must be explicit and safe.")
          bindings = files.to_h do |file|
            original = blob(reviewed, file)
            current = blob(head, file)
            assert!(original == current, "Review is stale for changed file #{file}; a fresh review is required.")
            [file, current]
          end
          report_path = directory.join(record.fetch("report_path")).realpath
          assert!(report_path.to_s.start_with?(directory.to_s + File::SEPARATOR) && REPORT_EXTENSIONS.include?(report_path.extname),
            "Review reports must be contained in the bundle directory and use a supported text format.")
          assert!(report_path.file? && report_path.size.positive? && report_path.size <= 2_000_000, "Review report is empty or too large.")
          bytes = report_path.binread
          assert!(bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding? && !bytes.strip.empty?, "Review report must contain UTF-8 text.")
          digest = Digest::SHA256.hexdigest(bytes)
          assert!(record["report_sha256"] == digest, "Review report digest does not match #{id}.")
          verify_cli!(bytes, files, record) if record["kind"] == "coderabbit_cli"
          record.except("report_path").merge(
            "source_head_sha" => head, "source_head_tree" => tree, "file_blobs" => bindings,
            "report_path" => "reviews/#{id}#{report_path.extname}", "report_bytes" => bytes
          )
        end

        def verify_findings!(record)
          findings = record["findings"]
          assert!(findings.is_a?(Array), "Review findings must be explicit.")
          valid = findings.all? do |finding|
            finding.is_a?(Hash) && text?(finding["reference"]) && text?(finding["disposition"]) &&
              ((finding["severity"] == "material" && finding["status"] == "resolved") ||
               (finding["severity"] == "nonblocking" && finding["status"] == "documented"))
          end
          assert!(valid, "Unresolved or unclassified review findings block capture.")
          assert!(record["outcome"] != "no_material_findings" || findings.none? { |finding| finding["severity"] == "material" },
            "Review outcome contradicts its material findings.")
        end

        def verify_cli!(bytes, files, record)
          events = bytes.lines.reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
          completion = events.last
          assert!(completion.is_a?(Hash) && completion["type"] == "complete" && completion["status"] == "review_completed" &&
            completion["findings"].is_a?(Integer) && completion["findings"] == record.fetch("findings").length &&
            completion["reviewedFiles"].is_a?(Array) && completion["reviewedFiles"].sort == files.sort,
            "CLI review must actually complete and match its declared file coverage.")
        end

        def safe_git_path?(file)
          text?(file) && !file.start_with?("/", "-") && !file.split("/").include?("..") && !file.include?("\0")
        end

        def blob(sha, path)
          entries = git("ls-tree", "-z", sha, "--", path).split("\0")
          entry = entries.find { |item| item.split("\t", 2).last == path }
          return "deleted" unless entry

          entry.split("\t", 2).first
        end

        def git(*arguments)
          @shell.capture!("git", *arguments, chdir: @root.to_s)
        end

        def json!(*command)
          JSON.parse(@shell.capture!(*command))
        end
    end
  end
end
