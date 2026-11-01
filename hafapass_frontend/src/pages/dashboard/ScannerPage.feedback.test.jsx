import 'fake-indexeddb/auto'
import { act, render as testingRender, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { MemoryRouter } from 'react-router-dom'
import apiClient from '../../api/client'
import { clearAllAdmissionData, clearEventAdmissionData, saveDevice, saveVerifiedManifest, sha256Hex } from '../../utils/admissionStore'
import { signedManifest } from '../../test/manifestFixture'
import { SCANNER_SOUND_KEY } from '../../hooks/useScanSound'
import ScannerPage, { ADMITTED_OVERLAY_MS } from './ScannerPage'

const render = element => testingRender(<MemoryRouter>{element}</MemoryRouter>)
const camera = vi.hoisted(() => ({ callbacks: [] }))
vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() }, getApiAuthContext: () => null, subscribeApiAuthContext: () => () => {} }))
vi.mock('@zxing/browser', () => ({ BrowserQRCodeReader: class {
  decodeFromVideoDevice(_device, _video, callback) { camera.callbacks.push(callback); return Promise.resolve({ stop: vi.fn() }) }
} }))

const eventId = 92101
const device = { id: 91, identifier: 'door-feedback', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
const overlay = () => screen.queryByTestId('scan-result-overlay')

// Records every tone the scanner schedules.
function installAudio() {
  const tones = []
  const contexts = []
  class FakeAudioContext {
    constructor() { this.state = 'running'; this.currentTime = 0; this.destination = {}; contexts.push(this) }
    resume() { return Promise.resolve() }
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
  return { tones, contexts }
}

async function prepareOffline(tickets) {
  await saveDevice(eventId, device)
  await saveVerifiedManifest(await signedManifest(eventId, tickets))
  window.localStorage.setItem('hafapass_scanner_event_id', String(eventId))
  render(<ScannerPage offlineOnly />)
  await waitFor(() => expect(screen.getByRole('button', { name: 'Start camera' })).toBeEnabled())
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
    expect(overlay()).toHaveFocus()
    expect(vibrate).toHaveBeenCalledWith([100, 60, 100])
    expect(screen.getByText('Invalid ticket')).toBeInTheDocument()
    await act(async () => { await new Promise(resolve => setTimeout(resolve, ADMITTED_OVERLAY_MS + 200)) })
    expect(overlay()).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Dismiss scan result' }))
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
    await user.keyboard('{Escape}')
    expect(overlay()).not.toBeInTheDocument()
  })

  it('a newer scan replaces a refusal that is still on screen', async () => {
    await prepareOffline([{ ticket_id: 504, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('camera-qr') }])
    await userEvent.click(screen.getByRole('button', { name: 'Start camera' }))
    await waitFor(() => expect(camera.callbacks).toHaveLength(1))
    await act(async () => camera.callbacks[0]({ getText: () => 'not-a-ticket' }))
    await waitFor(() => expect(overlay()).toHaveAttribute('data-result', 'error'))
    // The camera cool-down lets the next guest through without a tap.
    await act(async () => { await new Promise(resolve => setTimeout(resolve, 1900)) })
    await act(async () => camera.callbacks[0]({ getText: () => 'camera-qr' }))
    await waitFor(() => expect(overlay()).toHaveAttribute('data-result', 'success'))
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
