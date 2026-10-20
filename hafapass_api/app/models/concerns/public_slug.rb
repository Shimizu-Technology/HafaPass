# frozen_string_literal: true

# Shared rules for public link names (the :slug in /events/:slug and
# /venues/:slug). A record keeps every slug it gives up in a redirect table so
# old links continue to resolve; including models declare that table with
# `public_slug_redirects`.
module PublicSlug
  extend ActiveSupport::Concern

  FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  LENGTH = (3..80)
  # Route names and words that would make a link look like an official
  # HåfaPass page. Compared against the whole link name.
  RESERVED = %w[
    about account admin administrator api app billing browse cart checkout collections contact dashboard
    discover edit event events go hafa-pass hafapass help home index login logout my-tickets new null
    official og order orders organizer organizers payment payments policies policy preview refer refund
    refunds register root saved search security settings shimizu shimizu-technology sign-in sign-up signin
    signup sitemap staff support system team ticket tickets undefined venue venues verified www
  ].freeze

  # True when a save lost a race for a link name: two saves both passed the
  # availability check and the database's unique index rejected the second.
  def self.conflict?(error)
    error.message.match?(/index_(events|venues)_on_slug|index_(event|venue)_slug_redirects_on_slug/)
  end

  class_methods do
    attr_reader :slug_redirect_association

    def public_slug_redirects(association)
      @slug_redirect_association = association
      before_save :claim_slug_under_lock, if: :will_save_change_to_slug?
      after_save :retire_previous_slug, if: :saved_change_to_slug?
    end

    # Finds a record by its current slug, falling back to a retired one. A
    # hand-typed link in the wrong case or with stray spaces still resolves;
    # an exact match wins so legacy mixed-case links keep working.
    def find_by_public_slug(slug, scope: all)
      candidates = [slug.to_s, normalize_public_slug(slug)].uniq.reject(&:blank?)
      return if candidates.empty?

      redirects = scope.joins(slug_redirect_association)
      candidates.each do |candidate|
        record = scope.find_by(slug: candidate)
        return record if record
      end
      candidates.each do |candidate|
        record = redirects.find_by(slug_redirect_table => { slug: candidate })
        return record if record
      end
      nil
    end

    def find_by_public_slug!(slug, scope: all)
      find_by_public_slug(slug, scope: scope) || raise(ActiveRecord::RecordNotFound.new("Couldn't find #{name}", name))
    end

    def normalize_public_slug(value)
      value.to_s.strip.downcase
    end

    # Returns a sentence fragment explaining why +candidate+ cannot be used,
    # or nil when the link name is available for +record+.
    def public_slug_problem(candidate, record: nil)
      return "can't be blank" if candidate.blank?
      unless LENGTH.cover?(candidate.length)
        return "must be between #{LENGTH.min} and #{LENGTH.max} characters"
      end
      unless FORMAT.match?(candidate)
        return "can only use lowercase letters, numbers, and single hyphens between words"
      end
      return "is reserved. Choose a different link name" if RESERVED.include?(candidate)

      "is already used by another #{model_name.human.downcase}" if public_slug_taken?(candidate, record: record)
    end

    def public_slug_taken_message
      "#{human_attribute_name(:slug)} is already used by another #{model_name.human.downcase}"
    end

    def public_slug_taken?(candidate, record: nil)
      others = record&.id ? where.not(id: record.id) : all
      redirects = reflect_on_association(slug_redirect_association).klass
      foreign_key = reflect_on_association(slug_redirect_association).foreign_key
      other_redirects = record&.id ? redirects.where.not(foreign_key => record.id) : redirects
      others.exists?(slug: candidate) || other_redirects.exists?(slug: candidate)
    end

    private

    def slug_redirect_table
      reflect_on_association(slug_redirect_association).klass.table_name
    end
  end

  private

  # A generated slug follows the same rules as a custom one, with a short
  # random suffix when the readable base is too short, reserved, or taken.
  def unique_generated_slug(source, fallback:)
    base = source.to_s.parameterize.tr("_", "-").squeeze("-").delete_prefix("-").delete_suffix("-")
    base = base.first(PublicSlug::LENGTH.max - 7).delete_suffix("-").presence || fallback
    candidate = base
    while candidate.length < PublicSlug::LENGTH.min || PublicSlug::RESERVED.include?(candidate) ||
        self.class.public_slug_taken?(candidate, record: self)
      candidate = "#{base}-#{SecureRandom.hex(3)}"
    end
    candidate
  end

  # Validation checks availability outside any lock, so two saves can both
  # pass: one claiming a name while another retires it into the redirect
  # table, which no unique index spans. Inside the save transaction, lock the
  # name being claimed and the name being retired (one key space for live and
  # retired links, sorted so concurrent saves lock in the same order), then
  # check again. The locks are held until commit, after the redirect row is
  # written.
  def claim_slug_under_lock
    loop do
      [slug, slug_in_database].compact_blank.uniq.sort.each do |name|
        self.class.connection.select_value(self.class.sanitize_sql_array(
          ["SELECT 1 FROM pg_advisory_xact_lock(hashtext(?))", "#{self.class.table_name}_slug:#{name}"]
        ))
      end
      break unless self.class.public_slug_taken?(slug, record: self)

      if slug_chosen?
        errors.add(:slug, "is already used by another #{model_name.human.downcase}")
        throw :abort
      end
      source, fallback = generated_slug_source
      self.slug = unique_generated_slug(source, fallback: fallback)
    end
  end

  def retire_previous_slug
    previous, current = saved_change_to_slug
    return if previous.blank?

    redirects = public_send(self.class.slug_redirect_association)
    # Taking an old link name back makes it current again.
    redirects.where(slug: current).delete_all
    redirects.find_or_create_by!(slug: previous) if retain_previous_slug?
  end

  def retain_previous_slug?
    true
  end
end
