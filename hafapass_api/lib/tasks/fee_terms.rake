namespace :hafapass do
  desc "Post-deploy: move untouched 3% + 50c site fee defaults to the all-in 5% + $1.00 launch fee (idempotent, audited)"
  task adopt_launch_fee_terms: :environment do
    result = SiteSetting.adopt_launch_fee_terms!
    settings = SiteSetting.instance
    message = {
      adopted: "Adopted the launch fee terms",
      already_adopted: "Launch fee terms were already in place; nothing changed",
      custom: "An admin-chosen fee is set; nothing changed"
    }.fetch(result)
    puts "#{message}: #{settings.service_fee_percent}% + #{settings.service_fee_flat_cents}c per paid ticket, " \
      "processing borne by #{settings.processing_fee_bearer}."
  end
end
