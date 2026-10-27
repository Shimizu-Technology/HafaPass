abort 'Wrong database' unless ActiveRecord::Base.connection.select_value('SELECT current_database()') == 'hafapass_prepilot_b'
puts 'Verified throwaway database: hafapass_prepilot_b'
u = User.find_or_create_by!(clerk_id: 'prepilot-public-pages-qa') { |r| r.email='prepilot-public-pages@example.test'; r.first_name='Public QA'; r.role=:organizer }
o = OrganizerProfile.find_by(user: u)&.organization || Organization.find_or_create_by!(name: 'Public pages QA') { |r| r.name='Public pages QA'; r.timezone='Pacific/Guam'; r.currency='USD' }
OrganizationMembership.find_or_create_by!(organization: o, user: u) { |r| r.role=:owner; r.status=:active; r.accepted_at=Time.current }
p = OrganizerProfile.find_or_create_by!(organization: o) { |r| r.user=u; r.business_name='Public pages QA'; r.verification_status=:verified }
[['QA music night','concert',2500],['QA food gathering','dining',5900],['QA weekend workshop','workshop',0],['QA community festival','festival',1500]].each_with_index do |(title,category,price),i|
 e = Event.find_or_initialize_by(organization: o, title: title)
 e.assign_attributes(organizer_profile:p,organization:o,title:title,category:category,starts_at:(i+7).days.from_now.change(hour:18),ends_at:(i+7).days.from_now.change(hour:21),timezone:'Pacific/Guam',status: :published,is_featured:i==0,venue_name:'QA venue',venue_city:'Tamuning',description:'Local QA fixture. Not a real event.',fee_policy: :buyer_pays,buyer_fee_percent:100)
 e.save!
 e.ticket_types.find_or_create_by!(name:'General admission') { |r| r.price_cents=price; r.quantity_available=200 }
end
puts "Created #{o.events.count} QA events"
