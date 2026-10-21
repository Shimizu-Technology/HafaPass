# README

This README would normally document whatever steps are necessary to get the
application up and running.

Things you may want to cover:

* Ruby version

* System dependencies

* Configuration

* Database creation

* Database initialization

* How to run the test suite

* Services (job queues, cache servers, search engines, etc.)

* Deployment instructions

* ...

## Organizer tax information encryption

Set `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`,
`ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, and
`ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` in every deployed environment
(web and job services). Boot fails if any key is absent. Development and test
only have stable local fallback keys; never use them with real tax information.
Generate production values with `bin/rails db:encryption:init` in a secure terminal
and store them in the environment secret store. Preserve keys with backups;
changing keys without a rotation plan makes stored TINs unreadable.
