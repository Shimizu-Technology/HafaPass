# frozen_string_literal: true

# Used by scripts/rush_test/init_empty_db.sh: prints what the schema load produced.
puts "Loaded: #{ActiveRecord::Base.connection.tables.size} tables, payment_mode=#{SiteSetting.instance.payment_mode}"
