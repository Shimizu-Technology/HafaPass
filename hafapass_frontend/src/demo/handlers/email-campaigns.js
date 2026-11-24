// Preview-only email audiences, drafts and send history (checklist #19).
// Every name and address is fictional (@example.test); nothing is sent or saved.
// Add ?demo_email=worst|empty|one|huge to the page URL to load a worst-case set
// (reload resets the in-memory state).
import { created, json, notFound, unprocessable } from './respond'
import { DEMO_ORGANIZATION, DEMO_STAFF_USER } from '../staff/fixtures'

const FIRST = ['Avery', 'Bram', 'Calla', 'Dashiell', 'Elowen', 'Fenwick', 'Greer', 'Hollis', 'Ines', 'Juno', 'Kestrel', 'Linnea', 'Milo', 'Nadia', 'Orrin', 'Pilar', 'Quincy', 'Rowan', 'Saoirse', 'Tobin']
const LAST = ['Lindqvist', 'Okafor', 'Yorke', 'Pruitt', 'Marsh', 'Abara', 'Halvorsen', 'Vantongeren', 'Kowalczyk', 'Achterberg', 'Dunmore', 'Ostrova', 'Tarrant', 'Quenneville', 'Blackwood', 'Westergaard', 'Abernethy', 'Ellingsen', 'Pendleford', 'Harrowgate']
const SOURCES = ['footer', 'home', 'checkout', 'event_page', 'waitlist']
const INTERESTS = ['sports', 'music', 'food', 'family', 'nightlife']
const DAY = 86_400_000
const NOW = Date.parse('2026-11-24T09:00:00+10:00')
const iso = ms => new Date(ms).toISOString()

const WORST_PEOPLE = [
  { email: 'bartholomew.fitzgerald-vantongeren@northwind-industries-holdings.example.test', name: 'Bartholomew Fitzgerald-Vantongeren III' },
  { email: 'jo@example.test', name: 'Jo' },
  { email: 'kenji.ashgrove@example.test', name: '芦森 健二' },
  { email: 'mireille.oduya+events@example.test', name: 'Mireille Oduya 🎉🏀' },
  { email: 'ines.kowalczyk@example.test', name: 'Inès Kowalczyk-Wiśniewska' },
  { email: 'harriet.volkova@example.test', name: 'Гарриет Волкова' },
]

function person(index) {
  const first = FIRST[index % FIRST.length]
  const last = LAST[Math.floor(index / FIRST.length) % LAST.length]
  const suffix = index >= FIRST.length * LAST.length ? `.${Math.floor(index / (FIRST.length * LAST.length))}` : ''
  return { email: `${first}.${last}${suffix}@example.test`.toLowerCase(), name: `${first} ${last}` }
}

// statusPlan: [[status, count], ...]; `blocked` confirmed people opted out of all marketing.
function buildSubscribers(statusPlan, { blocked = 0, worst = false } = {}) {
  const rows = []
  let index = 0
  for (const [status, count] of statusPlan) {
    for (let i = 0; i < count; i += 1) {
      const who = worst && index < WORST_PEOPLE.length ? WORST_PEOPLE[index] : person(index)
      const createdAt = NOW - ((index * 7) % 90) * DAY - (index % 13) * 3_600_000
      rows.push({
        id: 7000 + index,
        email: who.email,
        name: index % 4 === 3 ? null : who.name,
        status,
        source: SOURCES[index % SOURCES.length],
        interests: [INTERESTS[index % INTERESTS.length], ...(index % 3 === 0 ? [INTERESTS[(index + 2) % INTERESTS.length]] : [])],
        villages: [],
        created_at: iso(createdAt),
        confirmed_at: status === 'pending' ? null : iso(createdAt + 3_600_000),
        all_marketing_blocked: status === 'confirmed' && i < blocked,
      })
      index += 1
    }
  }
  return rows.sort((a, b) => b.created_at.localeCompare(a.created_at))
}

function consentsFor(row) {
  const created = Date.parse(row.created_at)
  const list = [{ scope: 'platform', action: 'requested', version: 'event-alerts-v1', source: row.source, created_at: iso(created) }]
  if (row.status !== 'pending') list.unshift({ scope: 'platform', action: 'confirmed', version: 'event-alerts-v1', source: 'confirmation_link', created_at: iso(created + 3_600_000) })
  if (['unsubscribed', 'bounced', 'complained'].includes(row.status)) list.unshift({ scope: 'platform', action: row.status === 'unsubscribed' ? 'unsubscribed' : row.status, version: 'event-alerts-v1', source: row.status === 'unsubscribed' ? 'email_link' : 'provider', created_at: iso(created + 9 * DAY) })
  return list
}

// Organizer lists: `people` would get email, `considered` is everyone in that list.
const ORGANIZER_LISTS = {
  normal: { buyers: { considered: 540, people: 212 }, followers: { considered: 88, people: 81 }, waitlists: { considered: 40, people: 12 } },
  worst: { buyers: { considered: 61_204, people: 48_000 }, followers: { considered: 1, people: 1 }, waitlists: { considered: 37, people: 0 } },
  empty: { buyers: { considered: 0, people: 0 }, followers: { considered: 0, people: 0 }, waitlists: { considered: 0, people: 0 } },
  one: { buyers: { considered: 1, people: 1 }, followers: { considered: 1, people: 1 }, waitlists: { considered: 1, people: 1 } },
  huge: { buyers: { considered: 49_250, people: 48_000 }, followers: { considered: 1_204, people: 1_190 }, waitlists: { considered: 640, people: 233 } },
}

const PLATFORM_PLANS = {
  normal: { plan: [['confirmed', 314], ['pending', 9], ['unsubscribed', 7], ['bounced', 4], ['complained', 2]], blocked: 2 },
  worst: { plan: [['confirmed', 48_002], ['pending', 640], ['unsubscribed', 311], ['bounced', 97], ['complained', 4]], blocked: 2 },
  empty: { plan: [], blocked: 0 },
  one: { plan: [['confirmed', 1]], blocked: 0 },
  huge: { plan: [['confirmed', 48_010], ['pending', 820], ['unsubscribed', 310], ['bounced', 96], ['complained', 14]], blocked: 10 },
}

function mailing(id, fields) {
  return {
    id, organization_id: null, created_by_id: DEMO_STAFF_USER.id, audience: 'platform', status: 'queued', filters: {},
    cursor: 0, recipient_count: 0, blocked_reason: null, counts: {}, unsubscribed: 0, body: 'Upcoming events on Guam this month.', ...fields,
  }
}

function platformHistory(scenario) {
  if (scenario === 'empty') return []
  const list = [
    mailing(501, { subject: 'This weekend: Island Cup spectator day (demo)', status: 'queued', created_at: iso(NOW - 6 * DAY), scheduled_at: iso(NOW - 6 * DAY + 600_000), recipient_count: 298,
      body: 'Spectator tickets for the Island Cup (demo) are on sale now.\n\nChild $12 · Adult $17 · Under 5 free.\n\nSee you at the field house!',
      counts: { delivered: 281, sent: 6, bounced: 4, complained: 1, suppressed: 6 }, unsubscribed: 3 }),
    mailing(502, { subject: 'December events are here (demo)', status: 'scheduled', created_at: iso(NOW - DAY), scheduled_at: iso(NOW + 3 * DAY), recipient_count: 0, counts: {} }),
    mailing(503, { subject: 'Draft: New Year market (demo)', status: 'draft', created_at: iso(NOW - 2 * 3_600_000), scheduled_at: null, body: 'Save the date for the New Year night market (demo).' }),
    mailing(504, { subject: 'Holiday concert on sale (demo)', status: 'blocked', blocked_reason: 'Missing mailing address or marketing permission', created_at: iso(NOW - 12 * DAY), scheduled_at: iso(NOW - 12 * DAY) }),
    mailing(505, { subject: 'October recap (demo)', status: 'cancelled', created_at: iso(NOW - 30 * DAY), scheduled_at: iso(NOW - 28 * DAY) }),
  ]
  if (scenario === 'one') return [list[0]]
  if (scenario === 'worst' || scenario === 'huge') {
    list.unshift(mailing(500, {
      subject: '🎉 Last call — Island Cup spectator passes, food court map, parking shuttle times, and everything else you need for Saturday (demo) 島カップ',
      status: 'queueing', created_at: iso(NOW - 600_000), scheduled_at: iso(NOW - 540_000), recipient_count: 48_000, cursor: 1_300,
      counts: { queued: 46_800, sent: 900, delivered: 288, bounced: 12 }, unsubscribed: 1,
    }))
    for (let i = 0; i < 196; i += 1) {
      const when = NOW - (35 + i * 2) * DAY
      list.push(mailing(400 - i, { subject: `Weekly events roundup #${196 - i} (demo)`, status: 'queued', created_at: iso(when), scheduled_at: iso(when), recipient_count: 300 + i,
        counts: { delivered: 280 + i, bounced: i % 5, sent: 0 }, unsubscribed: i % 3 }))
    }
  }
  return list
}

function organizerHistory(scenario) {
  if (scenario === 'empty') return []
  const org = { organization_id: DEMO_ORGANIZATION.id }
  return [
    mailing(601, { ...org, audience: 'buyers', subject: 'Thanks for coming to the season opener (demo)', created_at: iso(NOW - 9 * DAY), scheduled_at: iso(NOW - 9 * DAY), recipient_count: 204,
      counts: { delivered: 199, bounced: 2, sent: 3 }, unsubscribed: 4 }),
    mailing(602, { ...org, audience: 'followers', subject: 'Finals tickets go on sale Monday (demo)', status: 'scheduled', created_at: iso(NOW - DAY), scheduled_at: iso(NOW + 4 * DAY) }),
  ]
}

function scenarioFromUrl() {
  const value = new URLSearchParams(globalThis.location?.search || '').get('demo_email')
  return ['worst', 'empty', 'one', 'huge'].includes(value) ? value : 'normal'
}

function emailState(state) {
  const scenario = scenarioFromUrl()
  if (state.emailCampaigns?.scenario === scenario) return state.emailCampaigns
  const { plan, blocked } = PLATFORM_PLANS[scenario]
  state.emailCampaigns = {
    scenario,
    subscribers: buildSubscribers(plan, { blocked, worst: scenario === 'worst' }),
    lists: structuredClone(ORGANIZER_LISTS[scenario]),
    mailings: [...platformHistory(scenario), ...organizerHistory(scenario)],
    nextId: 900,
  }
  return state.emailCampaigns
}

function platformFilter(rows, params) {
  const q = (params.get('q') || '').toLowerCase()
  const status = params.get('status')
  const source = params.get('source')
  const interest = params.get('interest')
  const since = params.get('since')
  return rows.filter(row => (!q || row.email.includes(q)) && (!status || row.status === status) && (!source || row.source === source)
    && (!interest || row.interests.includes(interest)) && (!since || row.created_at >= since))
}

const isEligible = row => row.status === 'confirmed' && !row.all_marketing_blocked

function audienceResponse(data, scope, params) {
  if (scope === 'platform') {
    const filtered = platformFilter(data.subscribers, params)
    const breakdown = {}
    for (const row of filtered) breakdown[row.status] = (breakdown[row.status] || 0) + 1
    const counts = {}
    for (const row of data.subscribers) counts[row.status] = (counts[row.status] || 0) + 1
    const growth = {}
    for (const row of data.subscribers) {
      if (Date.parse(row.created_at) < NOW - 90 * DAY) continue
      const day = row.created_at.slice(0, 10)
      growth[day] = (growth[day] || 0) + 1
    }
    return {
      subscribers: filtered.slice(0, 200).map(row => ({ ...row, consents: consentsFor(row) })),
      count: filtered.length, considered: filtered.length, counts, growth, status_breakdown: breakdown,
      eligible: filtered.filter(isEligible).length,
    }
  }
  const list = data.lists[params.get('audience') || 'buyers'] || { considered: 0, people: 0 }
  const q = (params.get('q') || '').toLowerCase()
  const shown = Math.min(list.people, 200)
  const emails = Array.from({ length: shown }, (_, index) => person(index + 40).email).filter(email => !q || email.includes(q))
  const eligible = q ? emails.length : list.people
  return { subscribers: emails.map(email => ({ email })), count: eligible, eligible, considered: q ? Math.max(eligible, Math.round(eligible * list.considered / Math.max(list.people, 1))) : list.considered }
}

const escapeHtml = value => String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char])

function previewHtml({ subject, body, sender }) {
  return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
<body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;margin:0;padding:20px;background-color:#f9fafb;">
<div style="max-width:600px;margin:0 auto;background:white;border-radius:12px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,0.1);">
<div style="background:linear-gradient(135deg,#0e7c7b 0%,#14a3a1 100%);padding:28px;text-align:center;"><h1 style="color:white;margin:0;font-size:26px;font-weight:700;letter-spacing:-0.5px;">HåfaPass</h1></div>
<div style="padding:36px 28px;"><h2>${escapeHtml(subject)}</h2><div style="white-space:pre-wrap">${escapeHtml(body)}</div>
<p>Sent by ${escapeHtml(sender)} through HåfaPass.</p><p>100 Example Street, Hagåtña, GU 96910 (demo address)</p>
<p><a href="#">Unsubscribe</a> · <a href="#">Email preferences</a></p></div>
<div style="background:#f9fafb;padding:20px 28px;text-align:center;border-top:1px solid #e5e7eb;"><p style="color:#9ca3af;margin:0;font-size:12px;">Demo preview. Nothing was sent.</p></div>
</div></body></html>`
}

function csvBlob(rows) {
  const text = rows.map(row => row.map(value => `"${String(value ?? '').replace(/"/g, '""')}"`).join(',')).join('\n')
  return typeof Blob === 'function' ? new Blob([text], { type: 'text/csv' }) : text
}

export async function handle({ method, path, body, params, state }) {
  if (!path.startsWith('/audience_mailings')) return undefined
  const data = emailState(state)
  const scope = (params.get('scope') || body.scope) === 'platform' ? 'platform' : 'organizer'
  const mine = row => (scope === 'platform' ? row.organization_id == null : row.organization_id === DEMO_ORGANIZATION.id)
  const sender = scope === 'platform' ? 'HåfaPass' : DEMO_ORGANIZATION.name

  if (method === 'get' && path === '/audience_mailings/audience') {
    const response = audienceResponse(data, scope, params)
    if (params.get('format') === 'csv') return json(csvBlob(response.subscribers.map(row => [row.email, row.status || ''])))
    return json(response)
  }
  if (method === 'get' && path === '/audience_mailings') {
    return json({ mailings: data.mailings.filter(mine).sort((a, b) => b.created_at.localeCompare(a.created_at)).slice(0, 100) })
  }
  if (method === 'post' && path === '/audience_mailings/preview') {
    if (!body.subject || !body.body) return unprocessable("Subject can't be blank")
    const audience = audienceResponse(data, scope, new URLSearchParams(Object.entries(body).filter(([, v]) => typeof v === 'string')))
    return json({ html: previewHtml({ subject: body.subject, body: body.body, sender }), eligible: audience.eligible })
  }
  if (method === 'post' && path === '/audience_mailings') {
    const id = (data.nextId += 1)
    const row = mailing(id, {
      organization_id: scope === 'platform' ? null : DEMO_ORGANIZATION.id, audience: scope === 'platform' ? 'platform' : body.audience || 'buyers',
      subject: body.subject, body: body.body, status: 'draft', created_at: new Date().toISOString(), scheduled_at: null,
      filters: Object.fromEntries(['q', 'status', 'source', 'interest', 'since'].filter(key => body[key]).map(key => [key, body[key]])),
    })
    data.mailings.unshift(row)
    return created(row)
  }
  const match = path.match(/^\/audience_mailings\/(\d+)\/(test_send|send_now|cancel)$/)
  if (method === 'post' && match) {
    const row = data.mailings.find(item => item.id === Number(match[1]) && mine(item))
    if (!row) return notFound()
    if (match[2] === 'test_send') return json({ queued: true, recipient: DEMO_STAFF_USER.email, demo: true })
    if (match[2] === 'cancel') {
      if (row.status !== 'scheduled') return json({ error: 'Conflict' }, 409)
      row.status = 'cancelled'
      return json(row)
    }
    if (row.status !== 'draft') return json({ error: 'Conflict' }, 409)
    const when = body.scheduled_at ? Date.parse(body.scheduled_at) : Date.now()
    if (Number.isNaN(when) || when < Date.now() - 60_000) return unprocessable('Invalid schedule')
    const audience = audienceResponse(data, scope, new URLSearchParams({ audience: row.audience, ...row.filters }))
    Object.assign(row, { scheduled_at: new Date(when).toISOString() })
    if (when > Date.now() + 60_000) row.status = 'scheduled'
    else Object.assign(row, { status: 'queued', recipient_count: audience.eligible, counts: { sent: audience.eligible } })
    return json(row)
  }
  const suppress = path.match(/^\/audience_mailings\/suppress\/(\d+)$/)
  if (method === 'post' && suppress && scope === 'platform') {
    const row = data.subscribers.find(item => item.id === Number(suppress[1]))
    if (!row) return notFound()
    if (!['bounced', 'complained'].includes(row.status)) row.status = 'unsubscribed'
    return json(null, 204)
  }
  return undefined
}
