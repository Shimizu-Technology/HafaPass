# frozen_string_literal: true

# When an alert incident opened, so a "recovered" notice can mean a success
# happened after that moment rather than that evidence aged out of a window.
class AddIncidentOpenedAtToRuntimeAlertStates < ActiveRecord::Migration[8.1]
  def change
    add_column :runtime_alert_states, :incident_opened_at, :datetime
  end
end
