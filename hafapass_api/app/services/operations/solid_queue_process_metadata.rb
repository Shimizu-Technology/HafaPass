# frozen_string_literal: true

module Operations
  module SolidQueueProcessMetadata
    def metadata
      super.merge(application_revision: ApplicationRevision.current, runtime_profile: RuntimeConfiguration.profile,
        runtime_instance: RuntimeConfiguration.instance_id)
    end
  end
end
