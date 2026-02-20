# frozen_string_literal: true

# Pagy pagination configuration
# https://ddnexus.github.io/pagy/

require "pagy/extras/limit"
require "pagy/extras/metadata"
require "pagy/extras/overflow"

# Default items per page
Pagy::DEFAULT[:limit] = 20

# Maximum items per page (prevents abuse)
Pagy::DEFAULT[:max_limit] = 100

# Handle overflow gracefully (return empty last page instead of error)
Pagy::DEFAULT[:overflow] = :empty_page
