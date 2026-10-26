import 'fake-indexeddb/auto'
import { act, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeAll, beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { Link, MemoryRouter, useNavigate } from 'react-router-dom'
import { clearAllAdmissionData, clearEventAdmissionData, loadAuthorizedScanner, loadPendingDeviceIdentity, queueAdmission, queuedActions, saveDevice, saveVerifiedManifest, sha256Hex } from './utils/admissionStore'
import { signedManifest } from './test/manifestFixture'

const state = vi.hoisted(() => ({ status: 'available', loaded: true, owner: 'staff-a', retry: vi.fn(), getToken: vi.fn() }))
const camera = vi.hoisted(() => ({ stops: [] }))
vi.mock('@zxing/browser', () => ({ BrowserQRCodeReader: class {
  decodeFromVideoDevice() { const stop = vi.fn(); camera.stops.push(stop); return Promise.resolve({ stop }) }
} }))
vi.mock('./hooks/useBackendAvailability', () => ({ useBackendAvailability: () => ({ status: state.status, retry: state.retry }) }))
vi.mock('@clerk/clerk-react', () => ({
  ClerkProvider: ({ children }) => children,
  useAuth: () => ({ getToken: state.getToken, isLoaded: state.loaded, userId: state.owner, sessionId: state.owner ? `session-${state.owner}` : null }),
  useUser: () => ({ isLoaded: state.loaded, isSignedIn: Boolean(state.owner), user: state.owner ? { id: state.owner } : null }),
}))
vi.mock('./api/client', () => ({ default: { get: vi.fn(), post: vi.fn() }, setAuthTokenGetter: vi.fn(), getApiAuthContext: () => null, subscribeApiAuthContext: () => () => {} }))
vi.mock('./monitoring', () => ({ Sentry: { setUser: vi.fn() } }))
vi.mock('./App', () => ({ default: () => <p>Online application</p> }))
vi.mock('./pages/PrivatePreviewPage', () => ({ default: () => <Link to="/dashboard/scanner?event=96801">Reopen ticket scanner</Link> }))

const eventId = 96801
let ServiceCheck
function NavigateHome() {
  const navigate = useNavigate()
  return <button onClick={() => navigate('/')}>Signout redirect</button>
}
const application = () => <MemoryRouter initialEntries={[`/dashboard/scanner?event=${eventId}`]}><NavigateHome /><ServiceCheck /></MemoryRouter>

describe('scanner authorization through actual service and auth boundaries', () => {
  beforeAll(async () => {
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'configured-test-key')
    ServiceCheck = (await import('./ServiceCheck')).default
  })
  beforeEach(async () => {
    window.localStorage.clear()
    window.sessionStorage.clear()
    camera.stops = []
    Object.assign(state, { status: 'available', loaded: true, owner: 'staff-a' })
    await clearAllAdmissionData()
    await clearEventAdmissionData(eventId)
    window.localStorage.setItem('hafapass_scanner_user_id', 'staff-a')
    await saveDevice(eventId, { id: 96, identifier: 'original-staff-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() })
    const ticket = { ticket_id: 501, state: 'admitted', attendee_name: 'Synthetic private attendee', ticket_type: 'Test entry', credential_hash: await sha256Hex('synthetic-private-qr') }
    await saveVerifiedManifest(await signedManifest(eventId, [ticket]))
    await queueAdmission({ eventId, deviceId: 96, manifestVersion: 1, ticket: { ticket_id: 502 }, credentialHash: 'f'.repeat(64), source: 'offline' })
    window.localStorage.setItem('hafapass_scanner_event_id', String(eventId))
  })
  afterEach(() => vi.unstubAllEnvs())

  it.each([null, 'staff-b'])('withdraws cached attendee access on confirmed identity change to %s during the API outage and after reopening', async owner => {
    const { rerender } = render(application())
    await screen.findByText('Online application')
    state.status = 'unavailable'
    rerender(application())
    await screen.findByText('Ticket list ready · 1 ticket')
    expect(screen.getByLabelText('Ticket QR code')).toBeEnabled()
    await userEvent.type(screen.getByLabelText('Ticket QR code'), 'synthetic-private-qr')
    await userEvent.click(screen.getByRole('button', { name: 'Check in ticket' }))
    expect(await screen.findByText(/Synthetic private attendee/)).toBeInTheDocument()

    state.owner = owner
    rerender(application())
    expect(screen.queryByText(/Synthetic private attendee/)).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Signout redirect' }))
    await userEvent.click(await screen.findByRole('link', { name: 'Reopen ticket scanner' }))
    await act(async () => { expect(await loadAuthorizedScanner(eventId)).toBeNull() })
    expect(screen.queryByText('Ticket list ready · 1 ticket')).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Ticket QR code')).not.toBeInTheDocument()
    expect(await queuedActions(eventId, 96)).toHaveLength(0)
    Object.assign(state, { owner: 'staff-a', status: 'available' })
    rerender(application())
    await screen.findByText('Online application')
    await act(async () => { expect(await queuedActions(eventId, 96)).toHaveLength(1) })
    expect(await loadPendingDeviceIdentity(eventId)).toMatchObject({ device_id: 96, identifier: 'original-staff-device' })
    expect(await loadAuthorizedScanner(eventId)).toBeNull()
  })

  it.each(['transition', 'fresh boot'])('keeps verified unexpired original-owner scanning available during genuine Clerk loading and the API outage (%s)', async entry => {
    if (entry === 'fresh boot') Object.assign(state, { status: 'unavailable', loaded: false })
    const { rerender } = render(application())
    if (entry === 'transition') {
      await screen.findByText('Online application')
      Object.assign(state, { status: 'unavailable', loaded: false })
      rerender(application())
    }
    expect(await screen.findByText('Ticket list ready · 1 ticket')).toBeInTheDocument()
    expect(screen.getByLabelText('Ticket QR code')).toBeEnabled()
    expect(screen.getByRole('button', { name: 'Reload to reconnect' })).toHaveAttribute('type', 'button')
    await act(async () => { expect(await queuedActions(eventId, 96)).toHaveLength(1) })
  })

  it.each(['pending', 'completed same owner'])('removes an already presented private result and stops its camera on peer-tab withdrawal while Clerk is still loading (%s)', async completion => {
    Object.assign(state, { status: 'unavailable', loaded: false })
    render(application())
    await screen.findByText('Ticket list ready · 1 ticket')
    await userEvent.type(screen.getByLabelText('Ticket QR code'), 'synthetic-private-qr')
    await userEvent.click(screen.getByRole('button', { name: 'Check in ticket' }))
    await screen.findByText(/Synthetic private attendee/)
    await userEvent.click(screen.getByRole('button', { name: 'Start camera' }))
    expect(camera.stops).toHaveLength(1)
    // A peer tab writes shared storage; it cannot call this tab's module state.
    window.localStorage.setItem('hafapass_scanner_binding_pending', 'peer-withdrawal')
    await act(async () => {
      await clearAllAdmissionData()
      if (completion === 'completed same owner') window.localStorage.removeItem('hafapass_scanner_binding_pending')
      window.dispatchEvent(new StorageEvent('storage', { key: 'hafapass_scanner_binding_pending', newValue: 'peer-withdrawal', storageArea: window.localStorage }))
    })
    expect(screen.queryByText(/Synthetic private attendee/)).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Ticket QR code')).not.toBeInTheDocument()
    expect(camera.stops[0]).toHaveBeenCalledOnce()
  })
})
