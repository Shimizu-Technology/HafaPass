# Rebrand the singleton's platform name only where it still holds the untouched
# default, and update the column default; an admin-customised name is left alone.
class BrandDefaultPlatformName < ActiveRecord::Migration[8.1]
  def up
    change_column_default :site_settings, :platform_name, from: "HafaPass", to: "HåfaPass"
    execute "UPDATE site_settings SET platform_name = 'HåfaPass', updated_at = CURRENT_TIMESTAMP WHERE platform_name = 'HafaPass'"
  end

  def down
    change_column_default :site_settings, :platform_name, from: "HåfaPass", to: "HafaPass"
    execute "UPDATE site_settings SET platform_name = 'HafaPass', updated_at = CURRENT_TIMESTAMP WHERE platform_name = 'HåfaPass'"
  end
end
