abort 'Wrong database' unless ActiveRecord::Base.connection.select_value('SELECT current_database()') == 'hafapass_prepilot_b'
u=User.find_by!(clerk_id: 'prepilot-public-pages-qa')
o=OrganizerProfile.find_by!(user: u).organization
abort 'Unexpected fixture events' unless o.events.count==4
if ARGV.first=='empty'
 o.events.update_all(status: Event.statuses.fetch('draft'))
else
 o.events.update_all(status: Event.statuses.fetch('published'))
end
puts "QA fixture state: #{ARGV.first}"
