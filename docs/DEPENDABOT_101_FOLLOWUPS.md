# Dependency upgrades deferred from PR #101

These upgrades need separate work before they can ship on the production ticketing API.

## Pagy 9.4.0 → 43.7.1

Pagy 43 removes the extras and `Pagy::Backend` used by `hafapass_api/config/initializers/pagy.rb` and `hafapass_api/app/controllers/concerns/paginatable.rb`. The attempted upgrade failed at boot with `cannot load such file -- pagy/extras/limit`. Follow the [Pagy 43 upgrade guide](https://ddnexus.github.io/pagy/guides/upgrade-guide/), then verify pagination limits, headers, metadata, and out-of-range pages across buyer, organizer, and admin lists. PR #101 retains 9.4.0 with the existing `~> 9.0` constraint.

## Sentry Rails and Ruby 5.28.1 → 7.1.0

[Sentry 7 release notes](https://github.com/getsentry/sentry-ruby/blob/master/CHANGELOG.md) say metrics are enabled by default and the Rails structured logging defaults changed. HåfaPass currently scrubs error events, transactions, and breadcrumbs through `TelemetryPrivacy`, but does not review or scrub the new log and metric payloads. Audit those payloads for ticket credentials and customer data, set explicit collection options, extend privacy tests, and verify monitoring behavior before upgrading both gems together. PR #101 retains 5.28.1.

## JSON 2.21.2 → 3.1.0

[JSON 3 release notes](https://github.com/ruby/json/blob/master/CHANGES.md) remove the `quirks_mode` parser option. The resolved HTTParty 0.24.3 still passes it, and `JSON.parse("{}", quirks_mode: true)` raises `ArgumentError` under JSON 3. Upgrade or replace that parser path, then verify provider responses and the canonical JSON used for offline admission manifests, payment evidence, and email replay before removing the `< 3` constraint. PR #101 retains 2.21.2.
