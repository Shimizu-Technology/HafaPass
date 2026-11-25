# frozen_string_literal: true

# Used by scripts/rush_test/init_empty_db.sh: exits non-zero unless the database has no tables.
tables = ActiveRecord::Base.connection.tables - %w[schema_migrations ar_internal_metadata]
abort("Refusing: database already has #{tables.size} tables") unless tables.empty?
puts "Database is empty."
