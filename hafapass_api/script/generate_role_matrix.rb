# frozen_string_literal: true

# No Rails boot, database, network or runtime services required.
require "json"
require_relative "../app/services/organization_roles"
require_relative "../app/services/organization_authorization"
require_relative "../app/services/organization_role_matrix"

outputs = {
  File.expand_path("../../hafapass_frontend/src/generated/roleMatrix.json", __dir__) => "#{JSON.pretty_generate(OrganizationRoleMatrix.data)}\n",
  File.expand_path("../../docs/ROLE_MATRIX.md", __dir__) => OrganizationRoleMatrix.markdown
}
if ARGV.include?("--check")
  outputs.each do |path, content|
    abort "Role matrix is stale: #{path}. Run ruby hafapass_api/script/generate_role_matrix.rb" unless File.exist?(path) && File.read(path) == content
  end
  puts "Role matrix is current."
else
  outputs.each do |path, content|
    File.write(path, content)
    puts "Generated #{path}"
  end
end
