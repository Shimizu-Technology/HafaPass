// Fictional staff-side fixtures for the preview-only demo layer. Every name,
// email and amount here is invented; nothing is saved anywhere. See ../README.md.
import roleMatrix from '../../generated/roleMatrix.json'
import { DEMO_EVENTS } from '../demoFixtures'

export const DEMO_STAFF_SENTINEL = 'HAFAPASS_DEMO_STAFF_SENTINEL_ISLA_2027'
export const DEMO_STAFF_CLERK_ID = 'demo_staff_user'
export const DEMO_STAFF_SESSION_ID = 'demo_staff_session'
export const DEMO_ORG_ID = 9001

export const DEMO_STAFF_USER = {
  id: 9100,
  clerk_id: DEMO_STAFF_CLERK_ID,
  email: 'demo.staff@example.invalid',
  first_name: 'Demo',
  last_name: 'Staffer',
  phone: null,
  role: 'admin',
  workspace: { organizations: 2, organizer: true, scanner: true },
  demo_marker: DEMO_STAFF_SENTINEL,
}

// Owner on the demo organization: every permission the role matrix grants.
export const DEMO_OWNER_PERMISSIONS = Object.fromEntries(
  [...new Set(Object.values(roleMatrix.permissions).flat())].map(key => [key, roleMatrix.permissions.owner.includes(key)]),
)

export const DEMO_ORGANIZATION = {
  id: DEMO_ORG_ID,
  name: 'Isla Demo Sports League',
  slug: 'isla-demo-sports-league',
  status: 'active',
  timezone: 'Pacific/Guam',
  currency: 'usd',
  role: 'owner',
  activity_access: true,
  activity_scope: 'demo',
  permissions: DEMO_OWNER_PERMISSIONS,
  payout_ready: true,
  marketing_mailing_address: '100 Example Street, Hagåtña, GU 96910',
  marketing_address_ready: true,
  fee_change_notice: null,
  admin_view: false,
}

export const DEMO_ORGANIZER_PROFILE = {
  id: 9201,
  organization: { id: DEMO_ORG_ID, name: DEMO_ORGANIZATION.name, slug: DEMO_ORGANIZATION.slug, status: 'active', role: 'owner' },
  business_name: DEMO_ORGANIZATION.name,
  business_description: 'Fictional organizer used for the preview. Nothing here is real.',
  logo_url: null,
  image_asset_host: null,
  is_ambros_partner: false,
  verification_status: 'verified',
  verification_requested_at: null,
  verification_request_version: 1,
  verified_at: '2026-10-01T09:00:00+10:00',
  verification_notes: null,
  verification_phone: null,
  verification_link: null,
  verification_request_note: null,
  policy_accepted_at: '2026-10-01T09:00:00+10:00',
  policy_version: 'demo',
  current_policy_version: 'demo',
  policy_accepted: true,
  payout_ready: true,
  connected_account: null,
  ready_to_publish_free_events: true,
  ready_to_publish_paid_events: true,
  setup_progress: { events_count: 3, published_events_count: 3, payout_method: 'manual' },
  created_at: '2026-09-15T09:00:00+10:00',
  updated_at: '2026-10-01T09:00:00+10:00',
}

const SOLD_DOOR = { door_allocation: null, door_sold_quantity: 0, door_held_quantity: 0, door_available_quantity: null }

// Organizer-side copies of three public demo events, owned by the demo organization.
function organizerEvent(source, extra = {}) {
  return {
    ...source,
    organization_id: DEMO_ORG_ID,
    organization_name: DEMO_ORGANIZATION.name,
    permissions: DEMO_OWNER_PERMISSIONS,
    custom_slug: null,
    slug_follows_title: true,
    ever_published: true,
    publicly_visible: true,
    organizer_verification_status: 'verified',
    policy_hold_scope: null,
    policy_hold: null,
    max_capacity: null,
    can_create_events: true,
    recurrence_rule: null,
    recurrence_parent_id: null,
    recurrence_end_date: null,
    fee_policy: 'buyer_pays',
    sales_status: 'on_sale',
    supported_locales: ['en'],
    localized_content: {},
    translation_status: {},
    automatic_translation_available: false,
    localized_content_stale: false,
    published_at: '2026-10-05T09:00:00+10:00',
    created_at: '2026-10-01T09:00:00+10:00',
    updated_at: '2026-11-01T09:00:00+10:00',
    publish_checklist: { ready: true, items: [] },
    state_history: [],
    ...extra,
    ticket_types: (source.ticket_types || []).map(type => ({
      ...SOLD_DOOR, sales_start_at: null, sales_end_at: null, is_pass: false, included_event_ids: [], included_events: [],
      attendee_info_mode: 'none', door_check_mode: 'standard', door_alert_label: null, door_instructions: null,
      scanner_show_buyer: true, max_per_buyer: null, on_sale: true, ...type,
    })),
  }
}

export function buildDemoOrganizerEvents() {
  const pick = slug => DEMO_EVENTS.find(event => event.slug === slug)
  return [
    organizerEvent(pick('copa-de-marianas-2027'), { title: 'Isla Demo Open 2027 (demo)' }),
    organizerEvent(pick('fd-alumni-basketball-night-1')),
    organizerEvent(pick('tumon-bay-acoustic-sessions'), { status: 'draft', ever_published: false, publicly_visible: false, published_at: null }),
  ]
}

const payout = (id, status, extra = {}) => ({
  id,
  created_at: '2026-11-10T10:00:00+10:00',
  organization: { id: DEMO_ORG_ID, name: DEMO_ORGANIZATION.name },
  event: { id: 101, title: 'Isla Demo Open 2027 (demo)' },
  settlement: { id: 8800 + id, version: 1 },
  amount_cents: 250000,
  withheld_cents: 0,
  carried_withholding_cents: 0,
  under_withheld_cents: 0,
  disbursement_cents: 250000,
  currency: 'usd',
  status,
  provider: 'manual',
  provider_payout_id: status === 'paid' ? 'demo_bank_ref_001' : null,
  failure_message: null,
  paid_at: status === 'paid' ? '2026-11-12T15:00:00+10:00' : null,
  allowed_outcomes: status === 'paid' ? [] : ['paid', 'failed'],
  hold_available_cents: 250000,
  outstanding_buyer_balance_cents: 0,
  cancellation_refunds_unresolved: false,
  event_cancelled: false,
  last_reconciliation: null,
  ...extra,
})

// One mutable bag per adapter instance (reset on reload). Handlers read and
// change it; nothing leaves the browser.
export function createDemoStaffState() {
  return {
    staff: {
      user: structuredClone(DEMO_STAFF_USER),
      organization: structuredClone(DEMO_ORGANIZATION),
      profile: structuredClone(DEMO_ORGANIZER_PROFILE),
      events: buildDemoOrganizerEvents(),
      payouts: [payout(7001, 'paid'), payout(7002, 'pending', { amount_cents: 120000, disbursement_cents: 120000, event: { id: 102, title: 'FD Alumni Basketball Night 1 (demo)' } })],
      boxOfficeSales: [],
      scans: [],
    },
  }
}
