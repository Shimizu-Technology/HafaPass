abort 'Wrong database' unless ActiveRecord::Base.connection.select_value('SELECT current_database()') == 'hafapass_prepilot_b'
SiteSetting.instance.update!(platform_email: 'public-pages-qa@example.test', payment_mode: 'live')
puts 'QA support mailbox configured; no messages will be sent'
