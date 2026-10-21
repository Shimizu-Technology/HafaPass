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
`ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` in every environment that collects
tax information (web and job services). Production boot fails if any key is
absent. Staging can boot without keys, but cannot store tax information until
all three are set. Development and test alone have stable local fallback keys;
never use them with real tax information.
Generate production values with `bin/rails db:encryption:init` in a secure terminal
and store them in the environment secret store. Preserve keys with backups;
changing keys without a rotation plan makes stored TINs unreadable.

### Organizer sales CSV amounts and access

The ticket CSV's **Ticket price**, **Discount**, **Fee**, and **Tax** columns are
allocated in integer cents from the saved order item across its tickets.
**Total paid** is ticket price minus discount plus fee and tax, before any
subsequent refund. Ticket rows sum to their saved order-item amounts; the order
view uses the saved order total. Financial columns require `view_finance`.
Attendee identity, contact, check-in, transfer, and notes/answers columns
require `view_attendees`. Queued exports are private S3 objects under
`private/sales-exports/<organization_id>/`. The bucket policy grants public reads
only under `uploads/`, so these objects remain private without an object ACL.
The authenticated actor can download them through the event API for two days.
The daily orphan sweep deletes unassociated objects after two days, including
uploads from workers that stopped while a request was still processing.
The worker's S3 credentials need `ListBucket` for that prefix and `DeleteObject`.
