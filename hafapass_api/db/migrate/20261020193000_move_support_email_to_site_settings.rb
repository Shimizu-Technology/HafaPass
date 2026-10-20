# The support inbox used to be hardcoded in the frontend; it is now data on the
# singleton (admin-editable, exposed by /config). Fill it only where the row is
# blank or still holds the old untouched column default "tickets@hafapass.com"
# (a domain HåfaPass does not own), and drop that column default. An address an
# admin chose is never rewritten. Rollback restores only the column default:
# the support address may since have been confirmed by an admin.
class MoveSupportEmailToSiteSettings < ActiveRecord::Migration[8.1]
  SUPPORT_EMAIL = "shimizutechnology@gmail.com"
  LEGACY_DEFAULT = "tickets@hafapass.com"

  def up
    change_column_default :site_settings, :platform_email, from: LEGACY_DEFAULT, to: nil
    execute <<~SQL.squish
      UPDATE site_settings SET platform_email = #{quote(SUPPORT_EMAIL)}, updated_at = CURRENT_TIMESTAMP
      WHERE platform_email IS NULL OR btrim(platform_email) = '' OR platform_email = #{quote(LEGACY_DEFAULT)}
    SQL
  end

  def down
    change_column_default :site_settings, :platform_email, from: nil, to: LEGACY_DEFAULT
  end

  private

  def quote(value)
    connection.quote(value)
  end
end
