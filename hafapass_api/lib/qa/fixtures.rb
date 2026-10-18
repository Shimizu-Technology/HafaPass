# frozen_string_literal: true

module Qa
  # Repeatable synthetic fixtures for an explicitly isolated local database.
  # This never resets data, creates Clerk accounts, or contacts money providers.
  class Fixtures
    class UnsafeEnvironment < StandardError; end

    ROLES = %w[organizer attendee scanner finance other_organizer].freeze

    def self.call(name: ENV.fetch("HAFAPASS_QA_NAME", "readiness"), identities: {})
      new(name: name, identities: identities).call
    end

    def initialize(name:, identities: {})
      @name = name
      @identities = identities.stringify_keys
    end

    def call
      verify_environment!
      result = nil
      ApplicationRecord.transaction do
        users = ROLES.index_with { |role| fixture_user(role) }
        organization, profile = organizer(users.fetch("organizer"), "main")
        other_organization, other_profile = organizer(users.fetch("other_organizer"), "other")
        membership(organization, users.fetch("scanner"), :scanner)
        membership(organization, users.fetch("finance"), :finance)

        events = 21.times.map { |index| event(profile, "event-#{index + 1}", index: index) }
        target = events.last
        EventStaffAssignment.find_or_create_by!(event: target, user: users.fetch("scanner"), role: :scanner) do |assignment|
          assignment.organization = organization
          assignment.assigned_by_user = users.fetch("organizer")
          assignment.status = :active
        end
        21.times { |index| order(target, index, users.fetch("attendee")) }
        cash_order = order(target, 22, users.fetch("attendee"), cash: true)
        free_event = event(profile, "free-registration", index: 22, price_cents: 0)
        other_event = event(other_profile, "other-organization", index: 23)

        result = {
          fixture_name: name, organization_id: organization.id,
          other_organization_id: other_organization.id,
          roles: users.transform_values { |user| { user_id: user.id, role: user.role } },
          event_count: events.length, scanner_event_id: target.id,
          refund_event_id: target.id, cash_order_reference: cash_order.reference,
          free_event_slug: free_event.slug, other_event_id: other_event.id,
          delivery: "simulated", payment_mode: "simulate"
        }
      end
      result
    end

    private

    attr_reader :name, :identities

    def verify_environment!
      config = ActiveRecord::Base.connection_db_config
      unless (Rails.env.development? || Rails.env.test?) && ENV["HAFAPASS_QA_FIXTURES"] == "1" &&
          config.adapter == "postgresql" && config.database.match?(/\Ahafapass_qa_[a-z0-9_]+\z/) &&
          local_connection?(config.configuration_hash)
        raise UnsafeEnvironment, "QA fixtures require development/test, HAFAPASS_QA_FIXTURES=1 and a local hafapass_qa_* database"
      end
      unless name.to_s.match?(/\A[a-z0-9][a-z0-9_-]{0,31}\z/) && (identities.keys - ROLES).empty?
        raise ArgumentError, "Use a short lowercase fixture name and only the documented QA roles"
      end
      subject_ids = ROLES.map { |role| identities[role].presence || "user_qa_#{name}_#{role}" }
      raise ArgumentError, "Each QA role needs a distinct Clerk subject" unless subject_ids.uniq.length == ROLES.length

      if %w[CLERK_SECRET_KEY CLERK_PUBLISHABLE_KEY].any? { |key| ENV[key].present? && ENV[key].include?("_live_") }
        raise UnsafeEnvironment, "QA fixtures require Clerk test keys"
      end
      unless SiteSetting.instance.simulate_mode? && EmailService.send(:delivery_provider) == "simulated"
        raise UnsafeEnvironment, "QA fixtures require simulated payments and simulated email"
      end
    end

    def local_connection?(parameters)
      # A service file can supply addresses that are absent from Rails' config.
      # Require explicit connection settings rather than trusting that indirection.
      return false unless parameters[:service].to_s.empty? && ENV["PGSERVICE"].to_s.empty?

      # Missing parameters inherit environment values independently: even
      # host=localhost does not override PGHOSTADDR. Treat empty values
      # conservatively too, rather than relying on driver-specific defaults.
      host = parameters[:host].to_s
      host = ENV["PGHOST"].to_s if host.empty?
      hostaddr = parameters[:hostaddr].to_s
      hostaddr = ENV["PGHOSTADDR"].to_s if hostaddr.empty?

      # Reject host lists too, including a socket path followed by a remote host.
      local_host = ["", "localhost", "127.0.0.1", "::1"].include?(host) ||
        (!host.include?(",") && host.start_with?("/", "@"))
      local_host && ["", "127.0.0.1", "::1"].include?(hostaddr)
    end

    def fixture_user(role)
      subject = identities[role].presence || "user_qa_#{name}_#{role}"
      user = User.find_or_create_by!(clerk_id: subject) do |record|
        record.role = role.include?("organizer") ? :organizer : :attendee
        record.email = "#{name}.#{role}@example.invalid"
        record.first_name = "QA"
        record.last_name = role.humanize
      end
      expected_role = role.include?("organizer") ? "organizer" : "attendee"
      unless user.role == expected_role
        raise UnsafeEnvironment, "The #{role} identity already has a different platform role; use a fresh isolated QA database"
      end
      user
    end

    def organizer(user, suffix)
      organization = Organization.find_or_create_by!(name: "QA #{name} #{suffix}") do |record|
        record.timezone = "Pacific/Guam"
        record.currency = "usd"
        record.status = :active
      end
      profile = OrganizerProfile.find_or_create_by!(user: user) do |record|
        record.organization = organization
        record.business_name = organization.name
        record.verification_status = :verified
        record.verified_at = Time.current
        record.policy_accepted_at = Time.current
        record.policy_version = PolicyRegistry.organizer_agreement[:version]
        record.policy_digest = PolicyRegistry.organizer_agreement[:digest]
      end
      raise UnsafeEnvironment, "QA identity already belongs to another organizer" unless profile.organization_id == organization.id

      membership(organization, user, :owner)
      [organization, profile]
    end

    def membership(organization, user, role)
      OrganizationMembership.find_or_create_by!(organization: organization, user: user) do |record|
        record.role = role
        record.status = :active
        record.accepted_at = Time.current
      end
    end

    def event(profile, suffix, index:, price_cents: 1000)
      record = profile.events.find_by(slug: "qa-#{name}-#{suffix}")
      return record if record

      record = profile.events.create!(organization: profile.organization,
        title: "QA #{name} #{suffix.humanize}", slug: "qa-#{name}-#{suffix}",
        description: "Synthetic local acceptance fixture", short_description: "Local QA event",
        venue_name: "QA Guam venue", venue_address: "Synthetic local address", venue_city: "Tumon",
        timezone: "Pacific/Guam", starts_at: 1.hour.from_now, ends_at: 6.hours.from_now,
        doors_open_at: 1.hour.ago, status: :published, published_at: Time.current,
        category: :other, age_restriction: :all_ages, max_capacity: 200)
      record.update_columns(created_at: index.minutes.ago)
      record.ticket_types.create!(name: "General Admission", price_cents: price_cents,
        quantity_available: 200, door_allocation: 20, max_per_order: 5)
      record
    end

    def order(event, index, user, cash: false)
      email = "#{name}.buyer#{index}@example.invalid"
      previous = event.orders.find_by(buyer_email: email)
      return previous if previous

      Commerce::OrderCreator.call(event: event,
        line_items: [{ ticket_type_id: event.ticket_types.first.id, quantity: 1 }],
        buyer_email: email, buyer_name: "QA Buyer #{index}", user: user,
        payment_required: false, service_fee: false,
        source: cash ? "box_office" : "online", payment_method: cash ? "door_cash" : nil).order
    end
  end
end
