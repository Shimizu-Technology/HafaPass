// Preview-only demo handler for real re-entry (Off / Exit scan / Cool-down),
// live headcount, lead overrides, and reporting hub re-entry metrics.
// Fictional names only; in-memory state resets on reload. See ../README.md.
import { json, notFound, unprocessable } from './respond'
import { canonicalJson, sha256Hex } from '../../utils/admissionStore'
import { evaluateLocalReEntry, serviceDayString } from '../../utils/reEntryRules'

export const DEMO_RE_ENTRY_SENTINEL = 'HAFAPASS_DEMO_RE_ENTRY_SENTINEL_2027'

const isoAgo = minutes => new Date(Date.now() - minutes * 60_000).toISOString()
const eventIdOf = path => path.match(/^\/organizer\/events\/(\d+)(?:\/|$)/)?.[1]

let signingKeys
async function signManifest(payload) {
  signingKeys ||= crypto.subtle.generateKey(
    { name: 'RSA-PSS', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  )
  const keys = await signingKeys
  const digest = await sha256Hex(canonicalJson(payload))
  const signature = await crypto.subtle.sign({ name: 'RSA-PSS', saltLength: 32 }, keys.privateKey, new TextEncoder().encode(digest))
  const publicKey = await crypto.subtle.exportKey('spki', keys.publicKey)
  const base64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes)))
  return {
    payload,
    digest,
    signature: base64(signature).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, ''),
    algorithm: 'PS256',
    key_id: await sha256Hex(publicKey),
    public_key_spki: base64(publicKey),
  }
}

function buildSingleEntryDemoEvent(template) {
  return {
    ...structuredClone(template),
    id: 104,
    title: 'Isla Harbor Night Market — Single Entry (demo)',
    slug: 'isla-harbor-night-market-demo',
    status: 'published',
    ever_published: true,
    publicly_visible: true,
    venue_name: 'Hagåtña Marina Pavilion (demo)',
    re_entry_mode: 'off',
    re_entry_max_count: null,
    re_entry_cutoff_time: null,
    re_entry_cooldown_minutes: null,
  }
}

function initReEntryState(state) {
  if (state.reEntry) return state.reEntry
  const { staff } = state
  const today = serviceDayString(Date.now(), { timezone: 'Pacific/Guam' })

  // Normalize publish_checklist to array for EditEventPage compatibility and
  // apply default re-entry modes across the demo events so preview users can test all three modes immediately.
  for (const ev of staff.events) {
    if (!Array.isArray(ev.publish_checklist)) ev.publish_checklist = []
  }
  const event101 = staff.events.find(e => e.id === 101)
  if (event101) {
    event101.re_entry_mode = 'exit_scan'
    event101.re_entry_max_count = 2
    event101.re_entry_cutoff_time = '23:30'
    event101.re_entry_cooldown_minutes = null
  }
  const event102 = staff.events.find(e => e.id === 102)
  if (event102) {
    event102.re_entry_mode = 'cooldown'
    event102.re_entry_max_count = 3
    event102.re_entry_cutoff_time = null
    event102.re_entry_cooldown_minutes = 15
  }
  const event103 = staff.events.find(e => e.id === 103)
  if (event103) {
    event103.re_entry_mode = 'off'
    event103.re_entry_max_count = null
    event103.re_entry_cutoff_time = null
    event103.re_entry_cooldown_minutes = null
  }
  if (!staff.events.some(e => e.id === 104) && event101) {
    staff.events.push(buildSingleEntryDemoEvent(event101))
  }

  const ticketsByEvent = {
    101: [
      { id: 9500, qr: 'demo-reentry-outside', attendee_name: 'Avery Lindqvist', ticket_type: 'Adult Spectator', state: 'valid', occupancy_state: 'outside', occupancy_day: null, last_entry_at: null, last_entry_gate: null, last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: false },
      { id: 9501, qr: 'demo-reentry-inside', attendee_name: 'Bram Okafor', ticket_type: 'Youth Spectator (Ages 5–17)', state: 'admitted', occupancy_state: 'inside', occupancy_day: today, last_entry_at: isoAgo(18), last_entry_gate: 'Gate 1', last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: false },
      { id: 9502, qr: 'demo-reentry-cap', attendee_name: 'Calla Yorke', ticket_type: 'Adult Spectator', state: 'admitted', occupancy_state: 'outside', occupancy_day: today, last_entry_at: isoAgo(42), last_entry_gate: 'Gate 2', last_exit_at: isoAgo(8), re_entry_count: 2, re_entry_conflict_flagged: false },
      { id: 9503, qr: 'demo-reentry-return', attendee_name: 'Dashiell Pruitt', ticket_type: 'Matside Bleacher Pass', state: 'admitted', occupancy_state: 'outside', occupancy_day: today, last_entry_at: isoAgo(50), last_entry_gate: 'Gate 1', last_exit_at: isoAgo(10), re_entry_count: 0, re_entry_conflict_flagged: false },
      { id: 9504, qr: 'demo-reentry-conflict', attendee_name: 'Elowen Marsh', ticket_type: 'Adult Spectator', state: 'admitted', occupancy_state: 'inside', occupancy_day: today, last_entry_at: isoAgo(24), last_entry_gate: 'Gate 1', last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: true },
      { id: 9505, qr: 'demo-reentry-long', attendee_name: 'Aleksandra Wiśniewska-Kowalczyk', ticket_type: 'VIP All-Access 2-Day Pass', state: 'valid', occupancy_state: 'outside', occupancy_day: null, last_entry_at: null, last_entry_gate: null, last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: false },
    ],
    102: [
      { id: 9600, qr: 'demo-cooldown-fresh', attendee_name: 'Fenwick Abara', ticket_type: 'General Admission', state: 'valid', occupancy_state: 'outside', occupancy_day: null, last_entry_at: null, last_entry_gate: null, last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: false },
      { id: 9601, qr: 'demo-cooldown-wait', attendee_name: 'Greer Halvorsen', ticket_type: 'General Admission', state: 'admitted', occupancy_state: 'inside', occupancy_day: today, last_entry_at: isoAgo(2), last_entry_gate: 'Main Entrance', last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: false },
      { id: 9602, qr: 'demo-cooldown-ready', attendee_name: 'Hollis Vantongeren', ticket_type: 'Courtside Seat', state: 'admitted', occupancy_state: 'inside', occupancy_day: today, last_entry_at: isoAgo(25), last_entry_gate: 'Main Entrance', last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: false },
      { id: 9603, qr: 'demo-cooldown-cap', attendee_name: 'Ines Kowalczyk', ticket_type: 'General Admission', state: 'admitted', occupancy_state: 'inside', occupancy_day: today, last_entry_at: isoAgo(30), last_entry_gate: 'Main Entrance', last_exit_at: null, re_entry_count: 3, re_entry_conflict_flagged: false },
      { id: 9604, qr: 'demo-cooldown-open-1', attendee_name: 'Juno Achterberg', ticket_type: 'General Admission', state: 'valid', occupancy_state: 'outside', occupancy_day: null, last_entry_at: null, last_entry_gate: null, last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: false },
      { id: 9605, qr: 'demo-cooldown-open-2', attendee_name: 'Kestrel Dunmore', ticket_type: 'Courtside Seat', state: 'valid', occupancy_state: 'outside', occupancy_day: null, last_entry_at: null, last_entry_gate: null, last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: false },
    ],
    104: [
      { id: 9700, qr: 'demo-off-1', attendee_name: 'Linnea Ostrova', ticket_type: 'Night Market Entry', state: 'valid', occupancy_state: 'outside', occupancy_day: null, last_entry_at: null, last_entry_gate: null, last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: false },
      { id: 9701, qr: 'demo-off-2', attendee_name: 'Milo Tarrant', ticket_type: 'Night Market Entry', state: 'admitted', occupancy_state: 'inside', occupancy_day: today, last_entry_at: isoAgo(15), last_entry_gate: 'South Gate', last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: false },
      { id: 9702, qr: 'demo-off-3', attendee_name: 'Nadia Quenneville', ticket_type: 'Night Market Entry', state: 'valid', occupancy_state: 'outside', occupancy_day: null, last_entry_at: null, last_entry_gate: null, last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: false },
      { id: 9703, qr: 'demo-off-4', attendee_name: 'Orrin Blackwood', ticket_type: 'Night Market Entry', state: 'valid', occupancy_state: 'outside', occupancy_day: null, last_entry_at: null, last_entry_gate: null, last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: false },
      { id: 9704, qr: 'demo-off-5', attendee_name: 'Pilar Westergaard', ticket_type: 'Night Market Entry', state: 'valid', occupancy_state: 'outside', occupancy_day: null, last_entry_at: null, last_entry_gate: null, last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: false },
      { id: 9705, qr: 'demo-off-6', attendee_name: 'Quincy Abernethy', ticket_type: 'Night Market Entry', state: 'valid', occupancy_state: 'outside', occupancy_day: null, last_entry_at: null, last_entry_gate: null, last_exit_at: null, re_entry_count: 0, re_entry_conflict_flagged: false },
    ],
  }

  state.reEntry = {
    sentinel: DEMO_RE_ENTRY_SENTINEL,
    manifestVersions: { 101: 1, 102: 1, 104: 1 },
    devices: {},
    ticketsByEvent,
    actionsByEvent: {
      101: [
        { action_uuid: 'demo-act-1', ticket_id: 9501, kind: 'admit', source: 'online', result: 'accepted', reason_code: 'admitted', occurred_at: isoAgo(18), received_at: isoAgo(18), occupancy_day: today, device_name: 'Gate 1', attendee: { code: 'HP-T9501', attendee_name: 'Bram Okafor', ticket_type: 'Youth Spectator (Ages 5–17)' } },
        { action_uuid: 'demo-act-2', ticket_id: 9504, kind: 'admit', source: 'offline', result: 'conflict', reason_code: 'already_inside', occurred_at: isoAgo(22), received_at: isoAgo(20), occupancy_day: today, device_name: 'Gate 2', attendee: { code: 'HP-T9504', attendee_name: 'Elowen Marsh', ticket_type: 'Adult Spectator' }, details: { prior_entry_at: isoAgo(24), prior_gate_name: 'Gate 1', offline_conflict: true } },
      ],
      102: [],
      104: [],
    },
    baselineStats: {
      101: { entries: 418, exits: 96, re_entries: 74, overrides: 2, peak_headcount: 394, peak_headcount_label: '3:05 PM', day1_headcount: 188 },
      102: { entries: 184, exits: 0, re_entries: 29, overrides: 0, peak_headcount: 184, peak_headcount_label: '7:40 PM', day1_headcount: 184 },
      104: { entries: 95, exits: 0, re_entries: 0, overrides: 0, peak_headcount: 95, peak_headcount_label: '6:30 PM', day1_headcount: 95 },
    },
    deltas: {
      101: { entries: 0, exits: 0, re_entries: 0, overrides: 0, headcount: 0 },
      102: { entries: 0, exits: 0, re_entries: 0, overrides: 0, headcount: 0 },
      104: { entries: 0, exits: 0, re_entries: 0, overrides: 0, headcount: 0 },
    },
  }
  return state.reEntry
}

function getDevice(reEntry, staff, event) {
  const key = String(event.id)
  if (!reEntry.devices[key]) {
    reEntry.devices[key] = {
      id: 9300 + Number(event.id),
      identifier: `demo-device-${event.id}`,
      name: event.id === 101 ? 'Gate 1 (demo)' : event.id === 102 ? 'Main Entrance (demo)' : 'South Gate (demo)',
      status: 'active',
      effective: true,
      authorization_expires_at: new Date(Date.now() + 24 * 3_600_000).toISOString(),
      last_manifest_version: reEntry.manifestVersions[event.id] || 1,
      last_manifest_digest: null,
      manifest_downloaded_at: isoAgo(1),
      last_synced_at: isoAgo(1),
      last_seen_at: isoAgo(1),
      last_sequence: 0,
      user: { id: staff.user.id, name: 'Demo Staffer' },
    }
  }
  return reEntry.devices[key]
}

function eventCounts(reEntry, event) {
  const tickets = reEntry.ticketsByEvent[event.id] || []
  const base = reEntry.baselineStats[event.id] || { entries: 0, exits: 0, re_entries: 0, overrides: 0, peak_headcount: 0, peak_headcount_label: null, day1_headcount: 0 }
  const delta = reEntry.deltas[event.id] || { entries: 0, exits: 0, re_entries: 0, overrides: 0, headcount: 0 }
  const admittedSample = tickets.filter(t => t.state === 'admitted').length
  const insideSample = tickets.filter(t => t.occupancy_state === 'inside').length
  const conflicts = (reEntry.actionsByEvent[event.id] || []).filter(a => a.result === 'conflict').length
  const flaggedCount = tickets.filter(t => t.re_entry_conflict_flagged).length
  const isOff = (event.re_entry_mode || 'off') === 'off'
  const liveHeadcount = isOff ? null : Math.max(0, (event.id === 101 ? 394 : insideSample) + delta.headcount)

  const headcountByDay = isOff
    ? []
    : event.id === 101
      ? [
          { day: '2026-11-23', label: 'Day 1 (Ended)', event_id: 101, event_title: 'Day 1 — Gi Divisions', entries: 240, exits: 52, re_entries: 41, headcount: 188, peak_headcount: 214, peak_headcount_at: '2026-11-23T14:15:00+10:00' },
          { day: serviceDayString(Date.now(), event), label: 'Day 2 (Today)', event_id: 101, event_title: 'Day 2 — No-Gi & Finals', entries: 178 + delta.entries, exits: 44 + delta.exits, re_entries: 33 + delta.re_entries, headcount: liveHeadcount, peak_headcount: Math.max(394, liveHeadcount), peak_headcount_at: '2026-11-24T15:05:00+10:00' },
        ]
      : [
          { day: serviceDayString(Date.now(), event), label: 'Event Day', event_id: event.id, entries: base.entries + delta.entries, exits: base.exits + delta.exits, re_entries: base.re_entries + delta.re_entries, headcount: liveHeadcount, peak_headcount: Math.max(base.peak_headcount, liveHeadcount) },
        ]

  return {
    total: tickets.length,
    issued: tickets.length - admittedSample,
    admitted: admittedSample,
    cancelled: 0,
    eligible_unadmitted: tickets.length - admittedSample,
    remaining: tickets.length - admittedSample,
    conflicts,
    rejected: 0,
    currently_inside: liveHeadcount,
    live_headcount: liveHeadcount,
    exits: base.exits + delta.exits,
    re_entries: base.re_entries + delta.re_entries,
    conflict_tickets: flaggedCount,
    headcount_by_day: headcountByDay,
  }
}

function buildReEntryReport(reEntry, event) {
  const counts = eventCounts(reEntry, event)
  const base = reEntry.baselineStats[event.id] || { entries: 0, exits: 0, re_entries: 0, overrides: 0, peak_headcount: 0, peak_headcount_label: null }
  const delta = reEntry.deltas[event.id] || { entries: 0, exits: 0, re_entries: 0, overrides: 0, headcount: 0 }
  const totalEntries = base.entries + delta.entries
  const totalExits = base.exits + delta.exits
  const totalReEntries = base.re_entries + delta.re_entries
  const totalOverrides = base.overrides + delta.overrides
  const peakHeadcount = Math.max(base.peak_headcount, counts.live_headcount)

  const byDay = event.id === 101
    ? [
        { day: '2026-11-23', label: 'Day 1', event_id: 101, event_title: 'Day 1 — Gi Divisions', entries: 240, exits: 52, re_entries: 41, overrides: 1, conflicts_count: 2, current_headcount: 188, peak_headcount: 214, peak_headcount_at: '2026-11-23T14:15:00+10:00', peak_headcount_label: '2:15 PM' },
        { day: serviceDayString(Date.now(), event), label: 'Day 2', event_id: 101, event_title: 'Day 2 — No-Gi & Finals', entries: 178 + delta.entries, exits: 44 + delta.exits, re_entries: 33 + delta.re_entries, overrides: 1 + delta.overrides, conflicts_count: counts.conflicts, current_headcount: counts.live_headcount ?? 0, peak_headcount: peakHeadcount, peak_headcount_at: '2026-11-24T15:05:00+10:00', peak_headcount_label: '3:05 PM' },
      ]
    : [
        { day: serviceDayString(Date.now(), event), label: 'Today', event_id: event.id, entries: totalEntries, exits: totalExits, re_entries: totalReEntries, overrides: totalOverrides, conflicts_count: counts.conflicts, current_headcount: counts.live_headcount ?? 0, peak_headcount: peakHeadcount, peak_headcount_at: isoAgo(30), peak_headcount_label: base.peak_headcount_label || '6:30 PM' },
      ]

  return {
    mode: event.re_entry_mode || 'off',
    max_count: event.re_entry_max_count ?? null,
    cutoff_time: event.re_entry_cutoff_time ?? null,
    cooldown_minutes: event.re_entry_cooldown_minutes ?? null,
    rollover_hour: 5,
    entries: totalEntries,
    exits: totalExits,
    re_entries: totalReEntries,
    overrides: totalOverrides,
    conflicts_count: counts.conflicts,
    current_headcount: counts.live_headcount ?? 0,
    peak_headcount: peakHeadcount,
    peak_headcount_at: byDay.at(-1)?.peak_headcount_at || null,
    peak_headcount_label: base.peak_headcount_label || '3:05 PM',
    by_day: byDay,
  }
}

async function buildSignedManifest(reEntry, event) {
  const tickets = reEntry.ticketsByEvent[event.id] || []
  const version = reEntry.manifestVersions[event.id] || 1
  const manifestTickets = await Promise.all(tickets.map(async t => ({
    ticket_id: t.id,
    code: `HP-T${t.id}`,
    credential_hash: await sha256Hex(t.qr),
    ticket_type: t.ticket_type,
    ticket_type_name: t.ticket_type,
    seat: null,
    state: t.state,
    occupancy_state: t.occupancy_state,
    occupancy_day: t.occupancy_day,
    last_entry_at: t.last_entry_at,
    last_entry_gate: t.last_entry_gate,
    last_exit_at: t.last_exit_at,
    re_entry_count: t.re_entry_count,
    re_entry_conflict_flagged: t.re_entry_conflict_flagged,
    reversed_admission_action_uuids: [],
    attendee_name: t.attendee_name,
    door_check_mode: 'instant',
    door_alert_label: null,
    door_instructions: null,
    door_fields: [],
  })))
  const now = Date.now()
  return signManifest({
    schema_version: 2,
    event: {
      id: event.id,
      title: event.title,
      status: event.status,
      venue_name: event.venue_name,
      starts_at: event.starts_at,
      ends_at: event.ends_at,
      timezone: event.timezone || 'Pacific/Guam',
      re_entry_mode: event.re_entry_mode || 'off',
      re_entry_max_count: event.re_entry_max_count ?? null,
      re_entry_cutoff_time: event.re_entry_cutoff_time ?? null,
      re_entry_cooldown_minutes: event.re_entry_cooldown_minutes ?? null,
      re_entry_rollover_hour: 5,
    },
    version,
    generated_at: new Date(now).toISOString(),
    expires_at: new Date(now + 12 * 3_600_000).toISOString(),
    tickets: manifestTickets,
  })
}

export async function handle(ctx) {
  const { method, path, params, body, state } = ctx
  const reEntry = initReEntryState(state)
  const { staff } = state

  const idStr = eventIdOf(path)
  if (!idStr) return undefined

  const event = staff.events.find(item => String(item.id) === idStr)
  if (!event) return undefined
  const rest = path.replace(`/organizer/events/${idStr}`, '') || ''

  // Save edited re-entry settings in memory
  if ((method === 'put' || method === 'patch') && rest === '') {
    if (body.re_entry_mode) event.re_entry_mode = body.re_entry_mode
    if ('re_entry_max_count' in body) event.re_entry_max_count = body.re_entry_max_count ? Number(body.re_entry_max_count) : null
    if ('re_entry_cooldown_minutes' in body) event.re_entry_cooldown_minutes = body.re_entry_cooldown_minutes ? Number(body.re_entry_cooldown_minutes) : null
    if ('re_entry_cutoff_time' in body) event.re_entry_cutoff_time = body.re_entry_cutoff_time || null
    reEntry.manifestVersions[event.id] = (reEntry.manifestVersions[event.id] || 1) + 1
    return json({ ...event, demo: true })
  }

  // Ticket type pricing tiers lookup on EditEventPage (keeps demo console clean)
  if (method === 'get' && /^\/ticket_types\/\d+\/pricing_tiers$/.test(rest)) {
    return json([])
  }

  // Event stats (EventOverviewPage live headcount)
  if (method === 'get' && rest === '/stats') {
    const counts = eventCounts(reEntry, event)
    return json({
      total_tickets_sold: 520,
      total_revenue_cents: 884000,
      tickets_checked_in: 418,
      live_headcount: counts.live_headcount,
      currently_inside: counts.currently_inside,
      exits_count: counts.exits,
      re_entries_count: counts.re_entries,
      headcount_by_day: counts.headcount_by_day,
      tickets_by_type: (event.ticket_types || []).map(tt => ({
        name: tt.name, sold: tt.quantity_sold || 80, available: tt.quantity_remaining || 120, revenue_cents: 240000,
      })),
    })
  }

  // Reports hub (EventReportsPage attendance + re_entry + CSV export)
  if (method === 'get' && rest === '/reports') {
    const type = params.get('report_type') || ''
    const reEntryReport = buildReEntryReport(reEntry, event)
    const attendance = {
      total_active_tickets: 520,
      checked_in_count: reEntryReport.entries,
      remaining_count: Math.max(0, 520 - reEntryReport.entries),
      check_in_rate: Number(((reEntryReport.entries / 520) * 100).toFixed(1)),
      timezone: event.timezone || 'Pacific/Guam',
      by_ticket_type: (event.ticket_types || []).map((tt, idx) => ({
        ticket_type_id: tt.id,
        ticket_type_name: tt.name,
        total_active_tickets: idx === 0 ? 320 : 200,
        checked_in_count: idx === 0 ? 258 : 160,
        remaining_count: idx === 0 ? 62 : 40,
        check_in_rate: idx === 0 ? 80.6 : 80.0,
      })),
      pace: [
        { bucket_start: '2027-01-30T08:00:00+10:00', label: '8:00 AM', count: 84 },
        { bucket_start: '2027-01-30T08:30:00+10:00', label: '8:30 AM', count: 142 },
        { bucket_start: '2027-01-30T09:00:00+10:00', label: '9:00 AM', count: 118 },
        { bucket_start: '2027-01-30T09:30:00+10:00', label: '9:30 AM', count: 74 },
      ],
      re_entry: reEntryReport,
    }
    const sales = {
      summary: { gross_sales_cents: 884000, net_sales_cents: 842000, total_refunded_cents: 42000, unique_orders: 214, tickets_issued: 520 },
      sales_by_tier: (event.ticket_types || []).map(tt => ({
        ticket_type_id: tt.id, ticket_type_name: tt.name, pricing_tier_id: null, tier_name: 'Standard',
        unit_price_cents: tt.current_price_cents || 1700, tickets_sold: 140, tickets_refunded_or_cancelled: 4,
        gross_cents: 238000, discount_cents: 0, net_cents: 231200, remaining_capacity: 60,
      })),
    }
    if (type === 'attendance') return json({ attendance, summary: { tickets_active: 520, tickets_checked_in: attendance.checked_in_count, check_in_rate: attendance.check_in_rate } })
    if (type === 'sales_by_tier') return json(sales)
    if (type === 'demographics') return json({ demographics: [] })
    if (type === 'payouts') return json({ payout_series: [] })
    return json({ ...sales, attendance, demographics: [], payout_series: [] })
  }

  if (method === 'get' && rest === '/reports/export.csv') {
    const report = buildReEntryReport(reEntry, event)
    const header = 'Day,Entries,Exits,Re-entries,Overrides,Current headcount,Peak headcount,Peak headcount time\n'
    const lines = report.by_day.map(d => `${d.day},${d.entries},${d.exits},${d.re_entries},${d.overrides},${d.current_headcount},${d.peak_headcount},${d.peak_headcount_label || ''}`).join('\n')
    return json(new Blob([`\uFEFF${header}${lines}\n`], { type: 'text/csv;charset=utf-8' }))
  }

  // Only handle scanner endpoints for events that have demo re-entry tickets
  if (!reEntry.ticketsByEvent[event.id]) return undefined
  const device = getDevice(reEntry, staff, event)
  const deviceBase = `/scanner_devices/${device.id}`

  if (method === 'get' && rest === '/scanner_devices') return json([device])
  if (method === 'post' && rest === '/scanner_devices') return json(device, 201)
  if (method === 'patch' && rest === deviceBase) return json(device)
  if (method === 'get' && rest === `${deviceBase}/manifest`) {
    return json(await buildSignedManifest(reEntry, event))
  }

  if (method === 'get' && rest === '/admissions') {
    const tickets = reEntry.ticketsByEvent[event.id] || []
    return json({
      event: {
        id: event.id, title: event.title, status: event.status, venue_name: event.venue_name,
        starts_at: event.starts_at, ends_at: event.ends_at, timezone: event.timezone || 'Pacific/Guam',
        re_entry_mode: event.re_entry_mode || 'off', re_entry_max_count: event.re_entry_max_count ?? null,
        re_entry_cutoff_time: event.re_entry_cutoff_time ?? null,
        re_entry_rollover_hour: event.re_entry_rollover_hour ?? 5, re_entry_cooldown_minutes: event.re_entry_cooldown_minutes ?? null,
      },
      counts: eventCounts(reEntry, event),
      devices: [{ id: device.id, name: device.name, status: 'active', effective: true, staff_name: 'Demo Staffer', last_seen_at: device.last_seen_at, last_synced_at: device.last_synced_at, last_manifest_version: device.last_manifest_version }],
      recent_actions: (reEntry.actionsByEvent[event.id] || []).slice(0, 20),
      flagged_conflicts: tickets.filter(t => t.re_entry_conflict_flagged).map(t => ({
        id: t.id, code: `HP-T${t.id}`, attendee_name: t.attendee_name, ticket_type: t.ticket_type,
        status: t.state === 'admitted' ? 'checked_in' : 'issued', occupancy_state: t.occupancy_state,
        last_entry_at: t.last_entry_at, last_entry_gate: t.last_entry_gate, re_entry_conflict_flagged: true,
      })),
      latest_manifest: { version: reEntry.manifestVersions[event.id] || 1, ticket_count: tickets.length },
      permissions: { can_recover: true, can_reverse: true, can_override: (event.re_entry_mode || 'off') !== 'off' },
    })
  }

  if (method === 'get' && rest === '/admissions/search') {
    const query = (params.get('q') || '').trim().toLowerCase()
    if (query.length < 2) return json([])
    const tickets = reEntry.ticketsByEvent[event.id] || []
    return json(
      tickets
        .filter(t => t.attendee_name.toLowerCase().includes(query) || `hp-t${t.id}`.includes(query))
        .map(t => ({
          id: t.id, code: `HP-T${t.id}`, attendee_name: t.attendee_name, ticket_type: t.ticket_type,
          seat: null, status: t.state === 'admitted' ? 'checked_in' : 'issued', checked_in_at: t.last_entry_at,
          admission_allowed: event.re_entry_mode !== 'off' || t.state !== 'admitted',
          occupancy_state: t.occupancy_state, last_entry_at: t.last_entry_at, last_entry_gate: t.last_entry_gate,
          re_entry_count: t.re_entry_count, re_entry_conflict_flagged: t.re_entry_conflict_flagged,
        })),
    )
  }

  if (method === 'post' && rest === `${deviceBase}/scan`) {
    const ticket = (reEntry.ticketsByEvent[event.id] || []).find(t => Number(t.id) === Number(body.ticket_id))
    if (!ticket) return json({ status: 'rejected', reason_code: 'credential_not_in_manifest' })
    const kind = body.kind || 'admit'
    const mode = event.re_entry_mode || 'off'
    const ticketPayload = {
      ticket_id: ticket.id, code: `HP-T${ticket.id}`, attendee_name: ticket.attendee_name,
      ticket_type: ticket.ticket_type, ticket_type_name: ticket.ticket_type, door_check_mode: 'instant', door_fields: [],
      occupancy_state: ticket.occupancy_state, occupancy_day: ticket.occupancy_day, re_entry_count: ticket.re_entry_count,
    }
    if (mode === 'off') {
      if (kind === 'exit') return json({ status: 'rejected', reason_code: 're_entry_disabled' })
      if (ticket.state === 'admitted') return json({ status: 'rejected', reason_code: 'already_admitted', ticket: ticketPayload })
      return json({ status: 'ready', verification_required: false, ticket: ticketPayload })
    }
    const decision = evaluateLocalReEntry({ kind, manifestTicket: ticket, localState: null, eventMeta: event })
    if (!decision.allowed) {
      return json({ status: 'rejected', reason_code: decision.reasonCode, details: decision.details || {}, ticket: ticketPayload })
    }
    return json({ status: 'ready', verification_required: false, re_entry: decision.isReEntry, re_entry_number: decision.reEntryNumber, ticket: ticketPayload })
  }

  if (method === 'post' && rest === `${deviceBase}/sync`) {
    const actions = Array.isArray(body.actions) ? body.actions : []
    const today = serviceDayString(Date.now(), event)
    const delta = reEntry.deltas[event.id]
    const mode = event.re_entry_mode || 'off'
    const results = actions.map((action, index) => {
      const ticket = (reEntry.ticketsByEvent[event.id] || []).find(t => Number(t.id) === Number(action.ticket_id))
      const nowIso = new Date().toISOString()
      const baseRes = {
        action_uuid: action.action_uuid, ticket_id: action.ticket_id, kind: action.kind, source: action.source,
        sequence: action.sequence ?? index + 1, occurred_at: action.occurred_at || nowIso, received_at: nowIso,
        attendee: ticket ? { code: `HP-T${ticket.id}`, attendee_name: ticket.attendee_name, ticket_type: ticket.ticket_type } : null,
      }
      if (!ticket) return { ...baseRes, result: 'rejected', reason_code: 'ticket_not_found' }

      if (action.kind === 'exit') {
        if (mode !== 'exit_scan') return { ...baseRes, result: 'rejected', reason_code: mode === 'off' ? 're_entry_disabled' : 're_entry_exit_not_used' }
        if (ticket.occupancy_state !== 'inside') return { ...baseRes, result: 'conflict', reason_code: 'not_inside' }
        ticket.occupancy_state = 'outside'
        ticket.last_exit_at = nowIso
        delta.exits += 1
        delta.headcount -= 1
        reEntry.manifestVersions[event.id] += 1
        const rec = { ...baseRes, result: 'accepted', reason_code: 'exited', ticket: { ticket_id: ticket.id, attendee_name: ticket.attendee_name, ticket_type: ticket.ticket_type, ticket_type_name: ticket.ticket_type, occupancy_state: 'outside', occupancy_day: today, re_entry_count: ticket.re_entry_count } }
        reEntry.actionsByEvent[event.id].unshift({ ...rec, device_name: device.name })
        return rec
      }

      if (mode === 'off') {
        if (ticket.state === 'admitted') return { ...baseRes, result: 'conflict', reason_code: 'already_admitted' }
        ticket.state = 'admitted'
        ticket.occupancy_state = 'inside'
        ticket.occupancy_day = today
        ticket.last_entry_at = nowIso
        ticket.last_entry_gate = device.name
        delta.entries += 1
        delta.headcount += 1
        reEntry.manifestVersions[event.id] += 1
        return { ...baseRes, result: 'accepted', reason_code: 'admitted', ticket: { ticket_id: ticket.id, attendee_name: ticket.attendee_name, ticket_type: ticket.ticket_type, ticket_type_name: ticket.ticket_type, occupancy_state: 'inside', occupancy_day: today, re_entry_count: 0 } }
      }

      const decision = evaluateLocalReEntry({ kind: 'admit', manifestTicket: ticket, localState: null, eventMeta: event })
      if (!decision.allowed) {
        return { ...baseRes, result: decision.type === 'warning' ? 'conflict' : 'rejected', reason_code: decision.reasonCode, details: decision.details || {} }
      }
      const wasOutside = ticket.occupancy_state !== 'inside'
      ticket.state = 'admitted'
      ticket.occupancy_state = 'inside'
      ticket.occupancy_day = today
      ticket.last_entry_at = nowIso
      ticket.last_entry_gate = device.name
      ticket.re_entry_count = decision.isReEntry ? decision.reEntryNumber : 0
      if (decision.isReEntry) delta.re_entries += 1
      else delta.entries += 1
      if (wasOutside) delta.headcount += 1
      reEntry.manifestVersions[event.id] += 1
      const rec = {
        ...baseRes,
        result: 'accepted',
        reason_code: decision.isReEntry ? 're_entered' : 'admitted',
        details: { re_entry: decision.isReEntry, re_entry_number: decision.reEntryNumber, gate_name: device.name },
        ticket: { ticket_id: ticket.id, attendee_name: ticket.attendee_name, ticket_type: ticket.ticket_type, ticket_type_name: ticket.ticket_type, occupancy_state: 'inside', occupancy_day: today, re_entry_count: ticket.re_entry_count },
      }
      reEntry.actionsByEvent[event.id].unshift({ ...rec, device_name: device.name })
      return rec
    })
    device.last_sequence = Math.max(device.last_sequence, ...results.map(r => Number(r.sequence) || 0))
    return json({ results, device, summary: eventCounts(reEntry, event) })
  }

  if (method === 'post' && rest === '/admissions/override') {
    if ((event.re_entry_mode || 'off') === 'off') {
      return unprocessable('Lead override is only available when re-entry is enabled for this event')
    }
    const ticket = (reEntry.ticketsByEvent[event.id] || []).find(t => Number(t.id) === Number(body.ticket_id))
    if (!ticket) return notFound('Ticket not found')
    const reason = String(body.reason || '').trim()
    if (reason.length < 3) return unprocessable('Provide a reason for the override (3–500 characters)')
    const overrideAction = body.override_action === 'clear' ? 'clear' : 'admit'
    const today = serviceDayString(Date.now(), event)
    const delta = reEntry.deltas[event.id]
    const wasInside = ticket.occupancy_state === 'inside'

    if (overrideAction === 'clear') {
      ticket.occupancy_state = 'outside'
      ticket.last_exit_at = new Date().toISOString()
      if (wasInside) delta.headcount -= 1
    } else {
      ticket.state = 'admitted'
      ticket.occupancy_state = 'inside'
      ticket.occupancy_day = today
      ticket.last_entry_at = new Date().toISOString()
      ticket.last_entry_gate = device.name
      if (!wasInside) delta.headcount += 1
    }
    ticket.re_entry_conflict_flagged = false
    delta.overrides += 1
    reEntry.manifestVersions[event.id] += 1

    const action = {
      action_uuid: body.action_uuid || crypto.randomUUID(),
      ticket_id: ticket.id,
      kind: 'override',
      result: 'accepted',
      reason_code: overrideAction === 'clear' ? 'lead_override_cleared' : 'lead_override_admitted',
      occurred_at: new Date().toISOString(),
      received_at: new Date().toISOString(),
      device_name: device.name,
      attendee: { code: `HP-T${ticket.id}`, attendee_name: ticket.attendee_name, ticket_type: ticket.ticket_type },
      details: { override_action: overrideAction },
    }
    reEntry.actionsByEvent[event.id].unshift(action)

    return json({
      action,
      ticket: { id: ticket.id, ticket_id: ticket.id, code: `HP-T${ticket.id}`, attendee_name: ticket.attendee_name, ticket_type: ticket.ticket_type, occupancy_state: ticket.occupancy_state, re_entry_conflict_flagged: false },
      summary: eventCounts(reEntry, event),
    })
  }

  return undefined
}
