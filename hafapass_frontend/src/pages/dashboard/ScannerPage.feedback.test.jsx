import 'fake-indexeddb/auto'
import { act, render as testingRender, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, onTestFinished, vi } from 'vitest'
import { MemoryRouter } from 'react-router-dom'
import apiClient from '../../api/client'
import { clearAllAdmissionData, clearEventAdmissionData, saveDevice, saveVerifiedManifest, sha256Hex } from '../../utils/admissionStore'
import { signedManifest } from '../../test/manifestFixture'
import { SCANNER_SOUND_KEY } from '../../hooks/useScanSound'
import ScannerPage, { ADMITTED_OVERLAY_MS, OVERLAY_TAP_GUARD_MS, SAME_CREDENTIAL_QUIET_MS } from './ScannerPage'

const render = element => testingRender(<MemoryRouter>{element}</MemoryRouter>)
const camera = vi.hoisted(() => ({ callbacks: [] }))
vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() }, getApiAuthContext: () => null, subscribeApiAuthContext: () => () => {} }))
vi.mock('@zxing/browser', () => ({ BrowserQRCodeReader: class {
  decodeFromVideoDevice(_device, _video, callback) { camera.callbacks.push(callback); return Promise.resolve({ stop: vi.fn() }) }
} }))

const eventId = 92101
const device = { id: 91, identifier: 'door-feedback', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
const overlay = () => screen.queryByTestId('scan-result-overlay')
const dismissButton = () => screen.getByRole('button', { name: /Dismiss scan result$/ })
// A newly shown overlay ignores taps briefly; wait until it accepts them.
const armed = () => waitFor(() => expect(overlay()).toHaveAttribute('data-armed', 'true'))
const wait = ms => act(async () => { await new Promise(resolve => setTimeout(resolve, ms)) })
const cameraRead = code => act(async () => camera.callbacks.at(-1)({ getText: () => code }))

// Records every tone the scanner schedules.
function installAudio() {
  const tones = []
  const contexts = []
  const resumes = []
  class FakeAudioContext {
    constructor() { this.state = 'running'; this.currentTime = 0; this.destination = {}; contexts.push(this) }
    resume() { resumes.push(this); return Promise.resolve() }
    close() { this.state = 'closed'; return Promise.resolve() }
    createGain() { return { gain: { setValueAtTime: vi.fn(), exponentialRampToValueAtTime: vi.fn() }, connect: vi.fn() } }
    createOscillator() {
      const tone = { type: null, frequency: null }
      tones.push(tone)
      return { set type(value) { tone.type = value }, frequency: { setValueAtTime: value => { tone.frequency = value } },
        connect: vi.fn(), start: vi.fn(), stop: vi.fn() }
    }
  }
  vi.stubGlobal('AudioContext', FakeAudioContext)
  return { tones, contexts, resumes }
}

async function prepareOffline(tickets) {
  await saveDevice(eventId, device)
  await saveVerifiedManifest(await signedManifest(eventId, tickets))
  window.localStorage.setItem('hafapass_scanner_event_id', String(eventId))
  render(<ScannerPage offlineOnly />)
  await waitFor(() => expect(screen.getByRole('button', { name: 'Start camera' })).toBeEnabled())
}

// A connected scanner whose sync replies are held until acknowledge() is called.
async function prepareOnline(tickets) {
  const manifest = await signedManifest(eventId, tickets)
  apiClient.get.mockImplementation(url => {
    if (url === '/organizer/events') return Promise.resolve({ data: { events: [{ id: eventId, status: 'published', title: 'Feedback Event' }] } })
    if (url.endsWith('/manifest')) return Promise.resolve({ data: manifest })
    if (url.endsWith('/search')) return Promise.resolve({ data: tickets.map(ticket => ({ id: ticket.ticket_id, code: `HP-T${ticket.ticket_id}`,
      attendee_name: ticket.attendee_name, ticket_type: ticket.ticket_type, status: 'issued', admission_allowed: true })) })
    return Promise.resolve({ data: { counts: { admitted: 0, remaining: tickets.length, conflicts: 0, rejected: 0 }, permissions: {}, recent_actions: [] } })
  })
  const replies = []
  apiClient.post.mockImplementation((url, payload) => {
    if (!url.endsWith('/sync')) return Promise.resolve({ data: device })
    const reply = { data: { device: { ...device, last_sequence: payload.actions.at(-1).sequence }, summary: {}, results: payload.actions.map(action => ({
      action_uuid: action.action_uuid, ticket_id: action.ticket_id, kind: action.kind, result: 'accepted', reason_code: 'admitted' })) } }
    return new Promise(resolve => { replies.push(() => resolve(reply)) })
  })
  render(<ScannerPage />)
  await waitFor(() => expect(screen.getByRole('button', { name: 'Start camera' })).toBeEnabled())
  return { acknowledge: async () => { await waitFor(() => expect(replies.length).toBeGreaterThan(0)); await act(async () => replies.shift()()) } }
}

async function enterCode(user, code) {
  await user.type(screen.getByLabelText('Ticket QR code'), code)
  await user.click(screen.getByRole('button', { name: 'Check in ticket' }))
}

describe('door scan feedback', () => {
  let vibrate
  beforeEach(async () => {
    vi.clearAllMocks()
    camera.callbacks = []
    window.localStorage.clear()
    await clearAllAdmissionData()
    await clearEventAdmissionData(eventId)
    vibrate = vi.fn()
    vi.stubGlobal('navigator', new Proxy(navigator, { get: (target, name) => name === 'vibrate' ? vibrate : Reflect.get(target, name) }))
  })
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); window.localStorage.clear() })

  it('flashes admitted full screen, then clears itself and keeps the result below the camera', async () => {
    await prepareOffline([{ ticket_id: 501, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('admit-qr') }])
    const user = userEvent.setup()
    await enterCode(user, 'admit-qr')
    await waitFor(() => expect(overlay()).toHaveAttribute('data-result', 'success'))
    expect(overlay()).toHaveClass('fixed', 'inset-0', 'z-[60]', 'bg-emerald-600')
    expect(overlay()).toHaveTextContent('Admitted')
    expect(overlay()).not.toHaveTextContent('Tap to continue')
    expect(overlay()).not.toHaveFocus()
    expect(vibrate).toHaveBeenCalledWith(80)
    const panel = screen.getByText('Admitted offline').closest('[role="status"]')
    expect(document.getElementById('scanner-camera').compareDocumentPosition(panel) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    await waitFor(() => expect(overlay()).not.toBeInTheDocument(), { timeout: ADMITTED_OVERLAY_MS + 1000 })
    expect(screen.getByText('Admitted offline')).toBeInTheDocument()
  })

  it('holds a refusal until tapped, returns focus, and lets the next scan through', async () => {
    await prepareOffline([{ ticket_id: 502, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('next-qr') }])
    const user = userEvent.setup()
    // Staff who submit with Enter get their place in the form back.
    await user.type(screen.getByLabelText('Ticket QR code'), 'unknown-qr{Enter}')
    await waitFor(() => expect(overlay()).toHaveAttribute('data-result', 'error'))
    expect(overlay()).toHaveClass('bg-red-700')
    expect(overlay()).toHaveTextContent('Do not admit')
    expect(overlay()).toHaveTextContent('Tap to continue')
    // A modal alert dialog that names the verdict and the reason.
    const dialog = screen.getByRole('alertdialog', { name: 'Do not admit' })
    expect(dialog).toBe(overlay())
    expect(dialog).toHaveAttribute('aria-modal', 'true')
    expect(dialog).toHaveAccessibleDescription('Invalid ticket')
    expect(screen.getByRole('button', { name: 'Do not admit. Dismiss scan result' })).toHaveFocus()
    expect(vibrate).toHaveBeenCalledWith([100, 60, 100])
    expect(screen.getByText('Invalid ticket')).toBeInTheDocument()
    // Focus stays inside the dialog while it is open.
    await user.tab()
    expect(dismissButton()).toHaveFocus()
    await user.tab({ shift: true })
    expect(dismissButton()).toHaveFocus()
    await wait(ADMITTED_OVERLAY_MS + 200)
    expect(overlay()).toBeInTheDocument()
    await user.click(dismissButton())
    expect(overlay()).not.toBeInTheDocument()
    expect(screen.getByLabelText('Ticket QR code')).toHaveFocus()
    expect(screen.getByText('Invalid ticket')).toBeInTheDocument()
    await enterCode(user, 'next-qr')
    await waitFor(() => expect(overlay()).toHaveAttribute('data-result', 'success'))
    expect(screen.getByText('Admitted offline')).toBeInTheDocument()
  })

  it('shows needs-attention results in amber and dismisses them with Escape', async () => {
    await prepareOffline([{ ticket_id: 503, state: 'admitted', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('used-qr') }])
    const user = userEvent.setup()
    await enterCode(user, 'used-qr')
    await waitFor(() => expect(overlay()).toHaveAttribute('data-result', 'warning'))
    expect(overlay()).toHaveClass('bg-amber-500', 'text-neutral-950')
    expect(overlay()).toHaveTextContent('Check ticket')
    expect(screen.getByText('Already admitted')).toBeInTheDocument()
    expect(screen.getByRole('alertdialog', { name: 'Check ticket' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Check ticket. Dismiss scan result' })).toHaveFocus()
    await armed()
    await user.keyboard('{Escape}')
    expect(overlay()).not.toBeInTheDocument()
  })

  it('ignores a dismiss tap or key that lands just as a refusal appears', async () => {
    await prepareOffline([])
    const user = userEvent.setup()
    await enterCode(user, 'stale-tap-qr')
    await waitFor(() => expect(overlay()).toHaveAttribute('data-result', 'error'))
    expect(overlay()).toHaveAttribute('data-armed', 'false')
    await user.click(dismissButton())
    await user.keyboard('{Escape}')
    expect(overlay()).toBeInTheDocument()
    await wait(OVERLAY_TAP_GUARD_MS + 50)
    expect(overlay()).toHaveAttribute('data-armed', 'true')
    await user.click(dismissButton())
    expect(overlay()).not.toBeInTheDocument()
  })

  it('pauses camera decisions while a refusal is on screen and resumes after the tap', async () => {
    await prepareOffline([{ ticket_id: 504, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('camera-qr') }])
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Start camera' }))
    await waitFor(() => expect(camera.callbacks).toHaveLength(1))
    await cameraRead('not-a-ticket')
    await waitFor(() => expect(overlay()).toHaveAttribute('data-result', 'error'))
    // After the cool-down the next guest's code is still not decided unseen.
    await wait(1900)
    await cameraRead('camera-qr')
    await wait(50)
    expect(overlay()).toHaveAttribute('data-result', 'error')
    expect(screen.queryByText('Admitted offline')).not.toBeInTheDocument()
    await armed()
    await user.click(dismissButton())
    expect(overlay()).not.toBeInTheDocument()
    // The refused code still in view stays ignored; the next guest goes through.
    await cameraRead('not-a-ticket')
    await wait(50)
    expect(overlay()).not.toBeInTheDocument()
    await cameraRead('camera-qr')
    await waitFor(() => expect(overlay()).toHaveAttribute('data-result', 'success'))
    expect(screen.getByText('Admitted offline')).toBeInTheDocument()
  })

  it('ignores the same code held in front of the camera after it is admitted, but not manual entry', async () => {
    vi.useFakeTimers({ toFake: ['Date'] })
    try {
      await prepareOffline([{ ticket_id: 506, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('held-qr') }])
      const user = userEvent.setup()
      await user.click(screen.getByRole('button', { name: 'Start camera' }))
      await waitFor(() => expect(camera.callbacks).toHaveLength(1))
      await cameraRead('held-qr')
      await waitFor(() => expect(screen.getByText('Admitted offline')).toBeInTheDocument())
      await waitFor(() => expect(overlay()).not.toBeInTheDocument(), { timeout: ADMITTED_OVERLAY_MS + 1000 })
      await wait(1900)
      // Still held up after the cool-down: no "Already scanned" and no amber.
      await cameraRead('held-qr')
      await wait(50)
      expect(overlay()).not.toBeInTheDocument()
      expect(screen.queryByText('Already scanned on this device')).not.toBeInTheDocument()
      // Each repeated read keeps the window open while the code stays in view.
      vi.setSystemTime(Date.now() + SAME_CREDENTIAL_QUIET_MS - 1000)
      await cameraRead('held-qr')
      vi.setSystemTime(Date.now() + SAME_CREDENTIAL_QUIET_MS - 1000)
      await cameraRead('held-qr')
      await wait(50)
      expect(screen.queryByText('Already scanned on this device')).not.toBeInTheDocument()
      // Out of view long enough, the same code is checked again.
      vi.setSystemTime(Date.now() + SAME_CREDENTIAL_QUIET_MS + 1)
      await cameraRead('held-qr')
      expect(await screen.findByText('Already scanned on this device')).toBeInTheDocument()
      expect(overlay()).toHaveAttribute('data-result', 'warning')
      await armed()
      await user.click(dismissButton())
      expect(overlay()).not.toBeInTheDocument()
      // The camera ignores the code again, but manual entry still checks it.
      await wait(1900)
      await cameraRead('held-qr')
      await wait(50)
      expect(overlay()).not.toBeInTheDocument()
      await enterCode(user, 'held-qr')
      await waitFor(() => expect(overlay()).toHaveAttribute('data-result', 'warning'))
    } finally {
      vi.useRealTimers()
    }
  }, 15_000)

  it('brings the result panel into view after a camera scan, without motion when reduced', async () => {
    // jsdom does not implement scrollIntoView.
    const scrollIntoView = vi.fn()
    Object.defineProperty(Element.prototype, 'scrollIntoView', { configurable: true, value: scrollIntoView })
    onTestFinished(() => { delete Element.prototype.scrollIntoView })
    await prepareOffline([{ ticket_id: 507, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('view-qr') }])
    Object.defineProperty(window, 'matchMedia', { configurable: true, value: query => ({ matches: query === '(prefers-reduced-motion: reduce)', media: query,
      addEventListener: vi.fn(), removeEventListener: vi.fn(), addListener: vi.fn(), removeListener: vi.fn() }) })
    onTestFinished(() => { delete window.matchMedia })
    const user = userEvent.setup()
    await enterCode(user, 'view-manual-qr')
    await waitFor(() => expect(overlay()).toHaveAttribute('data-result', 'error'))
    expect(scrollIntoView).not.toHaveBeenCalled()
    await armed()
    await user.click(dismissButton())
    await user.click(screen.getByRole('button', { name: 'Start camera' }))
    await waitFor(() => expect(camera.callbacks).toHaveLength(1))
    await cameraRead('view-qr')
    await waitFor(() => expect(scrollIntoView).toHaveBeenCalledWith({ block: 'nearest', behavior: 'auto' }))
    expect(scrollIntoView.mock.contexts.at(-1)).toBe(screen.getByText('Admitted offline').closest('[role="status"]'))
    expect(document.querySelector('#scanner-camera .relative')).toHaveClass('max-h-[60dvh]', 'landscape:max-h-[45dvh]')
  })

  it('clears an amber "Already scanned" overlay once the server confirms that admission', async () => {
    const { acknowledge } = await prepareOnline([{ ticket_id: 601, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('confirm-qr') }])
    const user = userEvent.setup()
    await enterCode(user, 'confirm-qr')
    expect(await screen.findByText('Waiting for server confirmation')).toBeInTheDocument()
    expect(overlay()).not.toBeInTheDocument()
    await enterCode(user, 'confirm-qr')
    expect(await screen.findByText('Already scanned on this device')).toBeInTheDocument()
    expect(overlay()).toHaveAttribute('data-result', 'warning')
    expect(vibrate).toHaveBeenCalledTimes(1)
    await acknowledge()
    expect(await screen.findByText('Admission confirmed')).toBeInTheDocument()
    expect(overlay()).not.toBeInTheDocument()
    expect(vibrate).toHaveBeenCalledTimes(1)
  })

  it('stays neutral while waiting online, flashes the verdict, and never flashes an Undo', async () => {
    const ticket = { ticket_id: 501, state: 'admitted', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('undo-qr') }
    const initial = await signedManifest(eventId, [ticket])
    const renewed = await signedManifest(eventId, [{ ...ticket, state: 'valid' }], { version: 2 })
    let manifestCalls = 0
    apiClient.get.mockImplementation(url => {
      if (url === '/organizer/events') return Promise.resolve({ data: { events: [{ id: eventId, status: 'published', title: 'Feedback Event' }] } })
      if (url.endsWith('/manifest')) return Promise.resolve({ data: ++manifestCalls === 1 ? initial : renewed })
      return Promise.resolve({ data: { counts: { admitted: 0, remaining: 1, conflicts: 0, rejected: 0 }, permissions: { can_reverse: true },
        recent_actions: [{ action_uuid: 'original-admission', ticket_id: 501, kind: 'admit', result: 'accepted', attendee: { attendee_name: 'Guest' } }] } })
    })
    let acknowledge = null
    apiClient.post.mockImplementation((url, payload) => {
      if (!url.endsWith('/sync')) return Promise.resolve({ data: device })
      const action = payload.actions[0]
      const reply = { data: { device: { ...device, last_sequence: action.sequence }, summary: {}, results: [{
        action_uuid: action.action_uuid, ticket_id: 501, kind: action.kind, result: 'accepted', reason_code: action.kind === 'reverse' ? 'reversed' : 'admitted' }] } }
      if (action.kind === 'reverse') return Promise.resolve(reply)
      return new Promise(resolve => { acknowledge = () => resolve(reply) })
    })
    render(<ScannerPage />)
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Undo admission for HP-T501' }))
    expect(await screen.findByText('Admission reversal confirmed')).toBeInTheDocument()
    expect(overlay()).not.toBeInTheDocument()
    expect(vibrate).not.toHaveBeenCalled()
    await user.click(screen.getByText('Device details', { exact: true }))
    await screen.findByText(/Saved ticket list · version 2/)
    await enterCode(user, 'undo-qr')
    await screen.findByText('Waiting for server confirmation')
    expect(overlay()).not.toBeInTheDocument()
    await waitFor(() => expect(acknowledge).not.toBeNull())
    await act(async () => acknowledge())
    expect(await screen.findByText('Admission confirmed')).toBeInTheDocument()
    expect(overlay()).toHaveAttribute('data-result', 'success')
    expect(vibrate).toHaveBeenCalledTimes(1)
  })
})

describe('door scan sound', () => {
  beforeEach(async () => {
    vi.clearAllMocks()
    camera.callbacks = []
    window.localStorage.clear()
    await clearAllAdmissionData()
    await clearEventAdmissionData(eventId)
  })
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); window.localStorage.clear() })

  it('unlocks audio on the Start camera tap and plays the admit and refuse tones', async () => {
    const audio = installAudio()
    const audioSession = { type: 'auto' }
    vi.stubGlobal('navigator', new Proxy(navigator, { get: (target, name) => name === 'audioSession' ? audioSession : Reflect.get(target, name) }))
    await prepareOffline([{ ticket_id: 505, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('tone-qr') }])
    expect(audio.contexts).toHaveLength(0)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Start camera' }))
    expect(audio.contexts).toHaveLength(1)
    expect(audioSession.type).toBe('playback')
    await waitFor(() => expect(camera.callbacks).toHaveLength(1))
    await act(async () => camera.callbacks[0]({ getText: () => 'tone-qr' }))
    await waitFor(() => expect(audio.tones).toEqual([{ type: 'sine', frequency: 880 }]))
    await act(async () => { await new Promise(resolve => setTimeout(resolve, 1900)) })
    await act(async () => camera.callbacks[0]({ getText: () => 'unknown-tone-qr' }))
    await waitFor(() => expect(audio.tones.slice(1)).toEqual([{ type: 'square', frequency: 220 }, { type: 'square', frequency: 220 }]))
  })

  it('resumes audio from every door tap so sound recovers after an iOS interruption', async () => {
    const audio = installAudio()
    await prepareOffline([])
    const user = userEvent.setup()
    expect(audio.contexts).toHaveLength(0)
    // Manual check-in is a tap: it creates (or resumes) the audio context.
    await enterCode(user, 'prime-unknown-qr')
    expect(audio.contexts).toHaveLength(1)
    expect(audio.resumes).toHaveLength(1)
    await waitFor(() => expect(overlay()).toHaveAttribute('data-result', 'error'))
    // Dismissing a refusal is a tap too.
    await armed()
    await user.click(dismissButton())
    expect(audio.resumes).toHaveLength(2)
    // Turning Sound back on resumes from that tap.
    const toggle = screen.getByRole('button', { name: 'Sound' })
    await user.click(toggle)
    expect(audio.resumes).toHaveLength(2)
    await user.click(toggle)
    expect(audio.resumes).toHaveLength(3)
    expect(audio.contexts).toHaveLength(1)
  })

  it('resumes audio from the attendee lookup Admit tap', async () => {
    const audio = installAudio()
    await prepareOnline([{ ticket_id: 602, state: 'valid', attendee_name: 'Lookup Guest', ticket_type: 'General', credential_hash: await sha256Hex('lookup-qr') }])
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Attendee name or ticket number'), 'Lookup')
    await user.click(screen.getByRole('button', { name: 'Search', exact: true }))
    const admit = await screen.findByRole('button', { name: 'Admit', exact: true })
    await waitFor(() => expect(admit).toBeEnabled())
    expect(audio.contexts).toHaveLength(0)
    await user.click(admit)
    expect(audio.contexts).toHaveLength(1)
    expect(audio.resumes).toHaveLength(1)
    expect(await screen.findByText('Waiting for server confirmation')).toBeInTheDocument()
  })

  it('remembers Sound off on this device and stays silent', async () => {
    const audio = installAudio()
    await prepareOffline([])
    const user = userEvent.setup()
    const toggle = screen.getByRole('button', { name: 'Sound' })
    expect(toggle).toHaveAttribute('aria-pressed', 'true')
    await user.click(toggle)
    expect(toggle).toHaveAttribute('aria-pressed', 'false')
    expect(window.localStorage.getItem(SCANNER_SOUND_KEY)).toBe('off')
    await user.click(screen.getByRole('button', { name: 'Start camera' }))
    await enterCode(user, 'silent-unknown-qr')
    await waitFor(() => expect(overlay()).toHaveAttribute('data-result', 'error'))
    expect(audio.tones).toHaveLength(0)
  })
})

describe('scanner screen wake lock', () => {
  const original = Object.getOwnPropertyDescriptor(navigator, 'wakeLock')
  beforeEach(async () => {
    vi.clearAllMocks()
    camera.callbacks = []
    window.localStorage.clear()
    await clearAllAdmissionData()
    await clearEventAdmissionData(eventId)
  })
  afterEach(() => {
    if (original) Object.defineProperty(navigator, 'wakeLock', original)
    else delete navigator.wakeLock
    vi.restoreAllMocks()
    window.localStorage.clear()
  })

  it('keeps the screen on only while the camera runs', async () => {
    const lock = { release: vi.fn().mockResolvedValue(), addEventListener: vi.fn() }
    const request = vi.fn().mockResolvedValue(lock)
    Object.defineProperty(navigator, 'wakeLock', { configurable: true, value: { request } })
    await prepareOffline([])
    expect(request).not.toHaveBeenCalled()
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Start camera' }))
    await waitFor(() => expect(request).toHaveBeenCalledWith('screen'))
    expect(screen.queryByText(/Set Auto-Lock or Screen timeout to Never/)).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Stop camera' }))
    expect(lock.release).toHaveBeenCalledTimes(1)
  })

  it('suggests a manual Auto-Lock setting when the browser cannot keep the screen on', async () => {
    delete navigator.wakeLock
    await prepareOffline([])
    expect(screen.queryByText(/Set Auto-Lock or Screen timeout to Never/)).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Start camera' }))
    expect(await screen.findByText('This browser can’t keep the screen on. Set Auto-Lock or Screen timeout to Never while scanning.')).toBeInTheDocument()
  })
})
