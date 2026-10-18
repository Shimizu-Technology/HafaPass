import 'fake-indexeddb/auto'
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import { clearAllAdmissionData } from '../../utils/admissionStore'
import { signedManifest } from '../../test/manifestFixture'
import ScannerPage from './ScannerPage'

vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() }, getApiAuthContext: () => null, subscribeApiAuthContext: () => () => {} }))
vi.mock('@zxing/browser', () => ({ BrowserQRCodeReader: class {} }))

const HOUR = 3_600_000
const at = offset => new Date(Date.now() + offset).toISOString()
const event = (id, status, startOffset, title = `Event ${id}`) => ({
  id, title, status, timezone: 'Pacific/Guam', starts_at: at(startOffset), ends_at: at(startOffset + 4 * HOUR),
})

beforeEach(async () => { vi.clearAllMocks(); window.localStorage.clear(); await clearAllAdmissionData() })
afterEach(async () => { vi.restoreAllMocks(); await clearAllAdmissionData(); window.localStorage.clear() })

async function mount(events, path = '/dashboard/scanner') {
  apiClient.get.mockImplementation(async requested => {
    if (requested === '/organizer/events') return { data: { events } }
    const manifestFor = requested.match(/events\/(\d+)\/scanner_devices\/\d+\/manifest$/)
    if (manifestFor) return { data: await signedManifest(Number(manifestFor[1])) }
    if (requested === '/me') return { data: { id: 7 } }
    return { data: { counts: {} } }
  })
  apiClient.post.mockResolvedValue({ data: { id: 92, identifier: 'default-event-device', effective: true, authorization_expires_at: at(600_000) } })
  return render(<MemoryRouter initialEntries={[path]}><ScannerPage /></MemoryRouter>)
}

it('skips a draft listed first and prepares the published event', async () => {
  await mount([event(93001, 'draft', 2 * HOUR, 'Draft first'), event(93002, 'published', 48 * HOUR, 'Published later')])
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('93002'))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/93002/scanner_devices', expect.anything()))
  expect(apiClient.post).not.toHaveBeenCalledWith('/organizer/events/93001/scanner_devices', expect.anything())
  expect(screen.getByRole('option', { name: 'Draft first' })).toBeInTheDocument()
})

it("prefers today's event over sooner-listed upcoming and past events", async () => {
  await mount([
    event(93011, 'published', 72 * HOUR, 'Next week'),
    event(93012, 'published', -72 * HOUR, 'Last week'),
    event(93013, 'published', -1 * HOUR, 'Happening now'),
    event(93014, 'cancelled', -1 * HOUR, 'Cancelled tonight'),
  ])
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('93013'))
})

it('prefers the soonest upcoming event, then the most recent past one', async () => {
  const { unmount } = await mount([event(93021, 'published', 240 * HOUR), event(93022, 'published', 48 * HOUR), event(93023, 'published', -48 * HOUR)])
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('93022'))
  unmount()
  await clearAllAdmissionData()
  window.localStorage.clear()
  await mount([event(93031, 'published', -240 * HOUR), event(93032, 'published', -48 * HOUR), event(93033, 'draft', 48 * HOUR)])
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('93032'))
})

it('keeps an explicit event in the URL ahead of the default choice', async () => {
  await mount([event(93041, 'published', -1 * HOUR, 'Happening now'), event(93042, 'published', 48 * HOUR, 'Requested')], '/dashboard/scanner?event=93042')
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('93042'))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/93042/scanner_devices', expect.anything()))
  expect(apiClient.post).not.toHaveBeenCalledWith('/organizer/events/93041/scanner_devices', expect.anything())
})

it('replaces a saved draft from the old default but keeps a saved published choice', async () => {
  window.localStorage.setItem('hafapass_scanner_event_id', '93051')
  const { unmount } = await mount([event(93051, 'draft', 2 * HOUR), event(93052, 'published', 48 * HOUR)])
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('93052'))
  unmount()
  await clearAllAdmissionData()
  window.localStorage.setItem('hafapass_scanner_event_id', '93062')
  await mount([event(93061, 'published', -1 * HOUR), event(93062, 'published', 48 * HOUR)])
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('93062'))
})

it('never auto-selects a draft when no published event is listed', async () => {
  await mount([event(93071, 'draft', 2 * HOUR, 'Only draft')])
  await waitFor(() => expect(screen.getByRole('option', { name: 'Only draft' })).toBeInTheDocument())
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue(''))
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  expect(apiClient.post).not.toHaveBeenCalled()
})
