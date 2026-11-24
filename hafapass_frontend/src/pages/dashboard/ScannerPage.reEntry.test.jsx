import 'fake-indexeddb/auto'
import { render as testingRender, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { MemoryRouter } from 'react-router-dom'
import apiClient from '../../api/client'
import { clearAllAdmissionData, clearEventAdmissionData, saveDevice, saveVerifiedManifest, sha256Hex } from '../../utils/admissionStore'
import { evaluateLocalReEntry, formatReEntryFeedback, serviceDayString } from '../../utils/reEntryRules'
import { signedManifest } from '../../test/manifestFixture'
import ScannerPage from './ScannerPage'
import ReEntrySettings from '../../components/admissions/ReEntrySettings'
import { AttendanceReport } from './EventReportViews'

const render = element => testingRender(<MemoryRouter>{element}</MemoryRouter>)
vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() }, getApiAuthContext: () => null, subscribeApiAuthContext: () => () => {} }))

const eventId = 93501
const device = { id: 55, name: 'Gate 1', identifier: 're-entry-dev', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }

function installAudio() {
  const tones = []
  class FakeAudioContext {
    constructor() { this.state = 'running'; this.currentTime = 0; this.destination = {} }
    resume() { return Promise.resolve() }
    close() { this.state = 'closed'; return Promise.resolve() }
    createGain() { return { gain: { setValueAtTime: vi.fn(), exponentialRampToValueAtTime: vi.fn() }, connect: vi.fn() } }
    createOscillator() {
      const tone = { type: null, frequency: null }
      tones.push(tone)
      return {
        set type(value) { tone.type = value },
        frequency: { setValueAtTime: value => { tone.frequency = value } },
        connect: vi.fn(), start: vi.fn(), stop: vi.fn(),
      }
    }
  }
  vi.stubGlobal('AudioContext', FakeAudioContext)
  return tones
}

async function prepareOfflineReEntry({ eventOverrides = {}, tickets = [] }) {
  await saveDevice(eventId, device)
  const envelope = await signedManifest(eventId, tickets, {
    schema_version: 2,
    event: {
      id: eventId,
      title: 'Copa Re-Entry Arena',
      timezone: 'Pacific/Guam',
      re_entry_mode: 'exit_scan',
      ...eventOverrides,
    },
  })
  await saveVerifiedManifest(envelope)
  window.localStorage.setItem('hafapass_scanner_event_id', String(eventId))
  render(<ScannerPage offlineOnly />)
  await waitFor(() => expect(screen.getByRole('button', { name: 'Start camera' })).toBeEnabled())
}

async function enterCode(user, code, buttonName = /Check in ticket|Scan exit/) {
  const input = screen.getByLabelText('Ticket QR code')
  await user.clear(input)
  await user.type(input, code)
  await user.click(screen.getByRole('button', { name: buttonName }))
}

describe('reEntryRules pure evaluation', () => {
  it('enforces anti-passback, exit scan, cooldown, cap, cutoff, and multi-day rollover', () => {
    const day1Ms = Date.parse('2027-01-30T14:00:00+10:00')
    const day2Ms = Date.parse('2027-01-31T09:00:00+10:00')
    const exitEvent = {
      timezone: 'Pacific/Guam',
      re_entry_mode: 'exit_scan',
      re_entry_max_count: 1,
      re_entry_cutoff_time: '18:00',
    }

    // Already inside on Day 1 -> blocked with anti-passback
    const insideDay1 = {
      state: 'admitted', occupancy_state: 'inside', occupancy_day: '2027-01-30',
      last_entry_at: '2027-01-30T13:00:00+10:00', last_entry_gate: 'Gate 1', re_entry_count: 0,
    }
    expect(evaluateLocalReEntry({ kind: 'admit', manifestTicket: insideDay1, localState: null, eventMeta: exitEvent, nowMs: day1Ms }))
      .toMatchObject({ allowed: false, reasonCode: 'already_inside', details: { prior_gate_name: 'Gate 1' } })

    // Same ticket on Day 2 -> Day 1 inside does NOT block Day 2 entry!
    expect(evaluateLocalReEntry({ kind: 'admit', manifestTicket: insideDay1, localState: null, eventMeta: exitEvent, nowMs: day2Ms }))
      .toMatchObject({ allowed: true, isReEntry: false, reEntryNumber: 0 })

    // Outside after 1 re-entry (cap = 1) -> blocked by cap
    const capHitTicket = { ...insideDay1, occupancy_state: 'outside', re_entry_count: 1 }
    expect(evaluateLocalReEntry({ kind: 'admit', manifestTicket: capHitTicket, localState: null, eventMeta: exitEvent, nowMs: day1Ms }))
      .toMatchObject({ allowed: false, reasonCode: 're_entry_limit_reached' })

    // Outside after daily cutoff on Day 1 -> blocked by cutoff
    const afterCutoffDay1Ms = Date.parse('2027-01-30T19:00:00+10:00')
    const outsideBeforeCap = { ...insideDay1, occupancy_state: 'outside', re_entry_count: 0 }
    expect(evaluateLocalReEntry({ kind: 'admit', manifestTicket: outsideBeforeCap, localState: null, eventMeta: exitEvent, nowMs: afterCutoffDay1Ms }))
      .toMatchObject({ allowed: false, reasonCode: 're_entry_cutoff_passed', details: { cutoff_time: '18:00' } })

    // Outside on Day 2 BEFORE 18:00 -> allowed (cutoff applies per service day, not a one-time datetime!)
    const day2Outside = { ...insideDay1, occupancy_state: 'outside', occupancy_day: '2027-01-31', re_entry_count: 0 }
    expect(evaluateLocalReEntry({ kind: 'admit', manifestTicket: day2Outside, localState: null, eventMeta: exitEvent, nowMs: Date.parse('2027-01-31T17:30:00+10:00') }))
      .toMatchObject({ allowed: true, isReEntry: true, reEntryNumber: 1 })
    // Outside on Day 2 AFTER 18:00 -> blocked
    expect(evaluateLocalReEntry({ kind: 'admit', manifestTicket: day2Outside, localState: null, eventMeta: exitEvent, nowMs: Date.parse('2027-01-31T18:15:00+10:00') }))
      .toMatchObject({ allowed: false, reasonCode: 're_entry_cutoff_passed' })

    // Cooldown mode: 2 min later blocked, 16 min later allowed
    const cooldownEvent = { timezone: 'Pacific/Guam', re_entry_mode: 'cooldown', re_entry_cooldown_minutes: 15 }
    const scannedAt = Date.parse('2027-01-30T13:00:00+10:00')
    expect(evaluateLocalReEntry({ kind: 'admit', manifestTicket: insideDay1, localState: null, eventMeta: cooldownEvent, nowMs: scannedAt + 2 * 60_000 }))
      .toMatchObject({ allowed: false, reasonCode: 'cooldown_active', details: { elapsed_minutes: 2, remaining_minutes: 13 } })
    expect(evaluateLocalReEntry({ kind: 'admit', manifestTicket: insideDay1, localState: null, eventMeta: cooldownEvent, nowMs: scannedAt + 16 * 60_000 }))
      .toMatchObject({ allowed: true, isReEntry: true, reEntryNumber: 1 })
  })

  it('keeps overnight events (20:00–02:00) on the same service day past midnight without resetting passback, exit, cooldown, or 01:00 cutoff', () => {
    const overnightEvent = {
      timezone: 'Pacific/Guam',
      starts_at: '2027-01-30T20:00:00+10:00',
      ends_at: '2027-01-31T02:00:00+10:00',
      re_entry_mode: 'exit_scan',
      re_entry_cutoff_time: '01:00',
    }
    const at2355 = Date.parse('2027-01-30T23:55:00+10:00')
    const at0005 = Date.parse('2027-01-31T00:05:00+10:00')
    const at0115 = Date.parse('2027-01-31T01:15:00+10:00')

    expect(serviceDayString(at2355, overnightEvent)).toBe('2027-01-30')
    expect(serviceDayString(at0005, overnightEvent)).toBe('2027-01-30')

    const inside = {
      state: 'admitted', occupancy_state: 'inside', occupancy_day: '2027-01-30',
      last_entry_at: '2027-01-30T23:55:00+10:00', last_entry_gate: 'Main Gate', re_entry_count: 0,
    }
    // 00:05 is still the same service day -> anti-passback holds and exit scan succeeds!
    expect(evaluateLocalReEntry({ kind: 'admit', manifestTicket: inside, localState: null, eventMeta: overnightEvent, nowMs: at0005 }))
      .toMatchObject({ allowed: false, reasonCode: 'already_inside' })
    expect(evaluateLocalReEntry({ kind: 'exit', manifestTicket: inside, localState: null, eventMeta: overnightEvent, nowMs: at0005 }))
      .toMatchObject({ allowed: true })

    // Re-entering at 00:10 is before 01:00 cutoff; at 01:15 is after 01:00 cutoff
    const outside = { ...inside, occupancy_state: 'outside' }
    expect(evaluateLocalReEntry({ kind: 'admit', manifestTicket: outside, localState: null, eventMeta: overnightEvent, nowMs: Date.parse('2027-01-31T00:10:00+10:00') }))
      .toMatchObject({ allowed: true, isReEntry: true, reEntryNumber: 1 })
    expect(evaluateLocalReEntry({ kind: 'admit', manifestTicket: outside, localState: null, eventMeta: overnightEvent, nowMs: at0115 }))
      .toMatchObject({ allowed: false, reasonCode: 're_entry_cutoff_passed' })

    // Cooldown across midnight: 23:55 entry + 15 min cooldown still blocks at 00:05
    const overnightCooldown = { ...overnightEvent, re_entry_mode: 'cooldown', re_entry_cooldown_minutes: 15, re_entry_cutoff_time: null }
    expect(evaluateLocalReEntry({ kind: 'admit', manifestTicket: inside, localState: null, eventMeta: overnightCooldown, nowMs: at0005 }))
      .toMatchObject({ allowed: false, reasonCode: 'cooldown_active' })
  })

  it('formats Already inside with gate time and gate name in Guam time', () => {
    const fb = formatReEntryFeedback('already_inside', {
      prior_entry_at: '2027-01-30T18:42:00+10:00',
      prior_gate_name: 'Gate 1',
    }, 'Pacific/Guam')
    expect(fb.message).toContain('Already inside')
    expect(fb.message).toContain('6:42 PM')
    expect(fb.message).toContain('Gate 1')
    expect(fb.soundKind).toBe('already_inside')
  })
})

describe('ScannerPage re-entry UX', () => {
  let vibrate
  beforeEach(async () => {
    vi.clearAllMocks()
    window.localStorage.clear()
    await clearAllAdmissionData()
    await clearEventAdmissionData(eventId)
    vibrate = vi.fn()
    vi.stubGlobal('navigator', new Proxy(navigator, { get: (target, name) => name === 'vibrate' ? vibrate : Reflect.get(target, name) }))
  })
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); window.localStorage.clear() })

  it('hides the Entry/Exit toggle and Inside now tile when mode is Off (no extra taps or headcount noise)', async () => {
    await prepareOfflineReEntry({
      eventOverrides: { re_entry_mode: 'off' },
      tickets: [{ ticket_id: 1, state: 'valid', attendee_name: 'Avery Lindqvist', ticket_type: 'General', credential_hash: await sha256Hex('off-1') }],
    })
    expect(screen.queryByTestId('re-entry-mode-toggle')).not.toBeInTheDocument()
    expect(screen.queryByTestId('scanner-live-headcount')).not.toBeInTheDocument()
  })

  it('shows big Entry/Exit switch in exit_scan mode, distinct Already inside sound/vibrate, Exit scan, and Re-entry', async () => {
    const tones = installAudio()
    const today = serviceDayString(Date.now(), { timezone: 'Pacific/Guam' })
    await prepareOfflineReEntry({
      eventOverrides: { re_entry_mode: 'exit_scan', re_entry_max_count: 2 },
      tickets: [
        {
          ticket_id: 101, state: 'valid', occupancy_state: 'outside', occupancy_day: null, re_entry_count: 0,
          attendee_name: 'Avery Lindqvist', ticket_type: 'Spectator', credential_hash: await sha256Hex('qr-101'),
        },
        {
          ticket_id: 102, state: 'admitted', occupancy_state: 'inside', occupancy_day: today,
          last_entry_at: new Date(Date.now() - 5 * 60_000).toISOString(), last_entry_gate: 'Gate 1', re_entry_count: 0,
          attendee_name: 'Bram Okafor', ticket_type: 'Spectator', credential_hash: await sha256Hex('qr-102'),
        },
      ],
    })

    const toggle = screen.getByTestId('re-entry-mode-toggle')
    const entryBtn = within(toggle).getByRole('button', { name: 'ENTRY' })
    const exitBtn = within(toggle).getByRole('button', { name: 'EXIT' })
    expect(entryBtn).toHaveAttribute('aria-pressed', 'true')
    expect(exitBtn).toHaveAttribute('aria-pressed', 'false')

    const user = userEvent.setup()
    // 1. Scan already-inside ticket at ENTRY -> anti-passback warning + distinct 3-pulse sound & vibration
    await enterCode(user, 'qr-102', 'Check in ticket')
    const warningOverlay = await screen.findByTestId('scan-result-overlay')
    expect(warningOverlay).toHaveAttribute('data-result', 'warning')
    expect(warningOverlay).toHaveTextContent('Already inside')
    expect(warningOverlay).toHaveTextContent('Gate 1')
    expect(vibrate).toHaveBeenCalledWith([120, 50, 120, 50, 180])
    expect(tones.filter(t => t.type === 'triangle').length).toBe(3)

    // Dismiss overlay
    await waitFor(() => expect(warningOverlay).toHaveAttribute('data-armed', 'true'))
    await user.click(screen.getByRole('button', { name: /Dismiss scan result/ }))

    // 2. Switch to EXIT mode -> EXIT MODE badge + Scan exit button
    await user.click(exitBtn)
    expect(exitBtn).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByText('EXIT MODE')).toBeInTheDocument()

    // Scan ticket 101 (not inside) at EXIT -> Not inside warning
    await enterCode(user, 'qr-101', 'Scan exit')
    const notInsideOverlay = await screen.findByTestId('scan-result-overlay')
    expect(notInsideOverlay).toHaveTextContent('Not inside')
    await waitFor(() => expect(notInsideOverlay).toHaveAttribute('data-armed', 'true'))
    await user.click(screen.getByRole('button', { name: /Dismiss scan result/ }))

    // Scan ticket 102 (inside) at EXIT -> sky-blue Exited overlay + exit vibration
    await enterCode(user, 'qr-102', 'Scan exit')
    const exitOverlay = await screen.findByTestId('scan-result-overlay')
    expect(exitOverlay).toHaveAttribute('data-result', 'exit_success')
    expect(exitOverlay).toHaveTextContent('Exited')
    expect(vibrate).toHaveBeenCalledWith([50, 40, 50])
  })

  it('shows live headcount formatted cleanly (including 9,999), per-day pills, and lead override for scanner leads', async () => {
    const manifest = await signedManifest(eventId, [{
      ticket_id: 201, state: 'admitted', occupancy_state: 'inside',
      attendee_name: 'Aleksandra Wiśniewska-Kowalczyk', ticket_type: '2-Day Pass',
      credential_hash: await sha256Hex('qr-201'),
    }], {
      schema_version: 2,
      event: { id: eventId, title: 'Copa 2027', timezone: 'Pacific/Guam', re_entry_mode: 'exit_scan' },
    })

    apiClient.get.mockImplementation(url => {
      if (url === '/organizer/events') return Promise.resolve({ data: { events: [{ id: eventId, status: 'published', title: 'Copa 2027', re_entry_mode: 'exit_scan' }] } })
      if (url.endsWith('/manifest')) return Promise.resolve({ data: manifest })
      return Promise.resolve({
        data: {
          event: { id: eventId, title: 'Copa 2027', re_entry_mode: 'exit_scan' },
          counts: {
            admitted: 9999, remaining: 1, conflicts: 1, rejected: 0, live_headcount: 9999,
            headcount_by_day: [
              { day: '2027-01-30', label: 'Jan 30, 2027', headcount: 4200 },
              { day: '2027-01-31', label: 'Jan 31, 2027', headcount: 9999 },
            ],
          },
          flagged_conflicts: [{
            id: 201, code: 'HP-T201', attendee_name: 'Aleksandra Wiśniewska-Kowalczyk',
            last_entry_gate: 'Gate 1', last_entry_at: '2027-01-30T18:42:00+10:00',
          }],
          permissions: { can_override: true, can_reverse: false },
          recent_actions: [],
        },
      })
    })
    apiClient.post.mockImplementation(url => {
      if (url.endsWith('/override')) {
        return Promise.resolve({
          data: {
            action: { action_uuid: 'ov-1', kind: 'override', reason_code: 'lead_override_cleared' },
            ticket: { id: 201, code: 'HP-T201', attendee_name: 'Aleksandra Wiśniewska-Kowalczyk', occupancy_state: 'outside' },
            summary: { admitted: 9999, remaining: 1, conflicts: 1, rejected: 0, live_headcount: 9998 },
          },
        })
      }
      return Promise.resolve({ data: device })
    })

    render(<ScannerPage />)
    expect(await screen.findByTestId('scanner-live-headcount')).toHaveTextContent('9,999')
    expect(screen.getByText(/Jan 30, 2027: 4,200 entered/)).toBeInTheDocument()
    expect(screen.getByText(/Flagged offline conflicts \(1\)/)).toBeInTheDocument()

    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Lead override' }))
    await user.type(screen.getByLabelText(/Reason for override/), 'Verified wristband at North Gate')
    await user.click(screen.getByRole('button', { name: 'Confirm override & Clear' }))

    await waitFor(() => expect(screen.getByTestId('scanner-live-headcount')).toHaveTextContent('9,998'))
    expect(apiClient.post).toHaveBeenCalledWith(
      `/organizer/events/${eventId}/admissions/override`,
      expect.objectContaining({ ticket_id: 201, override_action: 'clear', reason: 'Verified wristband at North Gate' }),
    )
  })

  it('labels cooldown mode as Entered instead of Inside now and defaults already-inside lead override to Admit (re-entry)', async () => {
    const today = serviceDayString(Date.now(), { timezone: 'Pacific/Guam' })
    const manifest = await signedManifest(eventId, [{
      ticket_id: 301, state: 'admitted', occupancy_state: 'inside', occupancy_day: today,
      last_entry_at: new Date(Date.now() - 2 * 60_000).toISOString(), last_entry_gate: 'Gate 1', re_entry_count: 0,
      attendee_name: 'Nadia Benavente', ticket_type: 'Spectator', credential_hash: await sha256Hex('qr-301'),
    }], {
      schema_version: 2,
      event: { id: eventId, title: 'Copa Cooldown', timezone: 'Pacific/Guam', re_entry_mode: 'cooldown', re_entry_cooldown_minutes: 15 },
    })
    apiClient.get.mockImplementation(url => {
      if (url === '/organizer/events') return Promise.resolve({ data: { events: [{ id: eventId, status: 'published', title: 'Copa Cooldown', re_entry_mode: 'cooldown' }] } })
      if (url.endsWith('/manifest')) return Promise.resolve({ data: manifest })
      return Promise.resolve({
        data: {
          event: { id: eventId, title: 'Copa Cooldown', timezone: 'Pacific/Guam', re_entry_mode: 'cooldown', re_entry_cooldown_minutes: 15 },
          counts: { admitted: 42, remaining: 58, conflicts: 0, rejected: 0, live_headcount: 42, headcount_by_day: [{ day: today, label: 'Today', headcount: 42 }] },
          flagged_conflicts: [],
          permissions: { can_override: true, can_reverse: false },
          recent_actions: [],
        },
      })
    })
    apiClient.post.mockImplementation(url => {
      if (url.endsWith('/scan')) {
        return Promise.resolve({
          data: {
            status: 'rejected',
            reason_code: 'already_inside',
            details: { prior_entry_at: new Date(Date.now() - 2 * 60_000).toISOString(), prior_gate_name: 'Gate 1' },
            ticket: { ticket_id: 301, code: 'HP-T301', attendee_name: 'Nadia Benavente', ticket_type: 'Spectator' },
          },
        })
      }
      return Promise.resolve({ data: device })
    })

    render(<ScannerPage />)
    const tile = await screen.findByTestId('scanner-live-headcount')
    expect(tile).toHaveTextContent('Entered')
    expect(tile).not.toHaveTextContent('Inside now')

    const user = userEvent.setup()
    await enterCode(user, 'qr-301', 'Check in ticket')
    const overlay = await screen.findByTestId('scan-result-overlay')
    await waitFor(() => expect(overlay).toHaveAttribute('data-armed', 'true'))
    await user.click(screen.getByRole('button', { name: /Lead override/i }))
    expect(screen.getByRole('radio', { name: /Admit \(re-entry\)/ })).toBeChecked()
  })
})

describe('ReEntrySettings & AttendanceReport re-entry views', () => {
  it('renders plain-language re-entry options, event timezone cutoff help, and live mid-event Off warning', async () => {
    const user = userEvent.setup()
    let form = { re_entry_mode: 'off', re_entry_max_count: '', re_entry_cutoff_time: '', re_entry_cooldown_minutes: '' }
    const updateField = vi.fn((k, v) => { form = { ...form, [k]: v } })
    const { rerender } = render(
      <ReEntrySettings form={form} updateField={updateField} timezone="America/New_York" savedMode="exit_scan" isLiveEvent />,
    )
    expect(screen.queryByLabelText(/Max re-entries/)).not.toBeInTheDocument()
    expect(screen.getByRole('alert')).toHaveTextContent(/switching re-entry to Off while this event is live/i)

    await user.click(screen.getByLabelText(/Cool-down/))
    expect(updateField).toHaveBeenCalledWith('re_entry_mode', 'cooldown')
    expect(updateField).toHaveBeenCalledWith('re_entry_cooldown_minutes', '15')

    rerender(
      <ReEntrySettings
        form={{ ...form, re_entry_mode: 'cooldown', re_entry_cooldown_minutes: '15' }}
        updateField={updateField}
        timezone="America/New_York"
        savedMode="exit_scan"
        isLiveEvent
      />,
    )
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(screen.getByLabelText(/Cool-down minutes/)).toHaveValue(15)
    expect(screen.getByLabelText(/Max re-entries per ticket/)).toBeInTheDocument()
    expect(screen.getByLabelText(/Daily re-entry cutoff time/)).toHaveAttribute('type', 'time')
    expect(screen.getByText(/Event time zone \(America\/New_York\)/)).toBeInTheDocument()
  })

  it('renders entries, exits, re-entries, peak headcount with time, and per-day table in AttendanceReport', () => {
    render(
      <AttendanceReport
        data={{
          total_active_tickets: 500,
          checked_in_count: 320,
          remaining_count: 180,
          check_in_rate: 64.0,
          timezone: 'Pacific/Guam',
          by_ticket_type: [],
          pace: [],
          re_entry: {
            mode: 'exit_scan',
            entries: 320,
            exits: 85,
            re_entries: 62,
            overrides: 2,
            current_headcount: 297,
            peak_headcount: 312,
            peak_headcount_label: '2:15 PM',
            by_day: [
              { day: '2027-01-30', label: 'Jan 30, 2027', entries: 320, exits: 85, re_entries: 62, overrides: 2, current_headcount: 297, peak_headcount: 312, peak_headcount_label: '2:15 PM' },
            ],
          },
        }}
      />,
    )
    expect(screen.getByRole('heading', { name: 'Re-entry & Headcount' })).toBeInTheDocument()
    expect(screen.getAllByText('312 · 2:15 PM').length).toBeGreaterThanOrEqual(1)
    expect(screen.getByRole('region', { name: 'Daily headcount and re-entry breakdown' })).toBeInTheDocument()
  })
})
