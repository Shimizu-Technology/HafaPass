# Specs build shipped migrations with Migration.new, which carries no version,
# so strong_migrations would check them as if they were new. Use the version in
# the migration's file name instead: exactly as under db:migrate, only
# migrations after StrongMigrations.start_after are checked.
module StrongMigrationsSpecVersion
  def version
    super || begin
      file = Object.const_source_location(@migration.class.name)&.first.to_s
      File.basename(file)[/\A(\d{14})_/, 1]&.to_i
    end
  end
end

StrongMigrations::Checker.prepend(StrongMigrationsSpecVersion)
