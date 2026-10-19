import 'fake-indexeddb/auto'
import { act, render, screen, waitFor } from '@testing-library/react'
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
  id, title, status, permissions: { scan: true }, timezone: 'Pacific/Guam', starts_at: at(startOffset), ends_at: at(startOffset + 4 * HOUR),
})

beforeEach(async () => { vi.clearAllMocks(); window.localStorage.clear(); await clearAllAdmissionData() })
afterEach(async () => { vi.useRealTimers(); vi.restoreAllMocks(); await clearAllAdmissionData(); window.localStorage.clear() })

async function mount(events, path = '/dashboard/scanner', { lookups = null, details = {} } = {}) {
  apiClient.get.mockImplementation(async (requested, config) => {
    if (requested === '/organizer/events') {
      if (lookups && config?.params?.status === 'published') return { data: { events: await lookups(config.params) } }
      return { data: { events, meta: { current_page: 1, total_pages: lookups ? 2 : 1 } } }
    }
    const detail = requested.match(/^\/organizer\/events\/(\d+)$/)
    if (detail) {
      if (details[detail[1]]) return { data: details[detail[1]] }
      throw Object.assign(new Error('Not found'), { response: { status: 404 } })
    }
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

it('ignores a saved draft that is only found through the off-page detail lookup', async () => {
  window.localStorage.setItem('hafapass_scanner_event_id', '93081')
  await mount([event(93082, 'published', 48 * HOUR, 'Published')], '/dashboard/scanner',
    { details: { 93081: { ...event(93081, 'draft', 2 * HOUR, 'Off-page draft'), organization_id: null } } })
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('93082'))
  expect(apiClient.get).toHaveBeenCalledWith('/organizer/events/93081', expect.anything())
  expect(apiClient.post).not.toHaveBeenCalledWith('/organizer/events/93081/scanner_devices', expect.anything())
  expect(screen.queryByRole('option', { name: /Off-page draft/ })).not.toBeInTheDocument()
})

it('never auto-selects a cancelled event, but an explicit or saved cancelled choice still opens', async () => {
  const { unmount } = await mount([event(93091, 'cancelled', -1 * HOUR, 'Cancelled tonight')])
  await waitFor(() => expect(screen.getByRole('option', { name: 'Cancelled tonight' })).toBeInTheDocument())
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue(''))
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  expect(apiClient.post).not.toHaveBeenCalled()
  unmount()

  for (const [path, saved] of [['/dashboard/scanner?event=93091', null], ['/dashboard/scanner', '93091']]) {
    vi.clearAllMocks()
    await clearAllAdmissionData()
    window.localStorage.clear()
    if (saved) window.localStorage.setItem('hafapass_scanner_event_id', saved)
    const view = await mount([event(93091, 'cancelled', -1 * HOUR, 'Cancelled tonight')], path)
    await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('93091'))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/93091/scanner_devices', expect.anything()))
    view.unmount()
  }
})

it('finds the best published event on a later page without changing the visible page', async () => {
  const lookups = vi.fn(params => params.order === 'starts_at' ? [event(93102, 'published', -1 * HOUR, 'Tonight on page 2')] : [])
  await mount([event(93101, 'published', -240 * HOUR, 'Old page 1 event')], '/dashboard/scanner', { lookups })
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('93102'))
  expect(lookups).toHaveBeenCalledWith(expect.objectContaining({ purpose: 'scan', status: 'published', order: 'starts_at', per_page: 50, ends_after: expect.any(String) }))
  expect(screen.getByRole('option', { name: 'Old page 1 event' })).toBeInTheDocument()
  expect(screen.getByRole('option', { name: 'Tonight on page 2 (selected)' })).toBeInTheDocument()
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/93102/scanner_devices', expect.anything()))
})

it('falls back to the latest published event across pages when none is current or upcoming', async () => {
  const lookups = vi.fn(params => params.order === '-starts_at' ? [event(93112, 'published', -48 * HOUR, 'Last weekend')] : [])
  await mount([event(93111, 'published', -720 * HOUR, 'Last month'), event(93113, 'draft', 48 * HOUR)], '/dashboard/scanner', { lookups })
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('93112'))
  expect(lookups).toHaveBeenCalledWith(expect.objectContaining({ status: 'published', order: '-starts_at', per_page: 20 }))
})

it('keeps the DOM in phone reading order instead of reordering focusable content with CSS', async () => {
  const { container } = await mount([event(93121, 'published', -1 * HOUR, 'Tonight')])
  await screen.findByRole('heading', { name: 'Door totals' })
  const sequence = [
    screen.getByLabelText('Event to scan'),
    screen.getByRole('button', { name: 'Sync now' }),
    screen.getByRole('button', { name: 'Start camera' }),
    screen.getByRole('button', { name: 'Download emergency door list' }),
    screen.getByRole('link', { name: 'Use camera' }),
    screen.getByLabelText('Ticket QR code'),
    screen.getByLabelText('Find an event'),
    screen.getByText('Device details'),
  ]
  sequence.slice(1).forEach((element, index) => {
    expect(sequence[index].compareDocumentPosition(element) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })
  const reordered = [...container.querySelectorAll('[class]')].filter(element => /(^|\s)(order-|contents(\s|$)|flex-row-reverse)/.test(element.className))
  expect(reordered).toEqual([])
})

it('falls back to the visible page when the cross-page lookup hangs past its deadline', async () => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'], shouldAdvanceTime: true })
  const lookups = vi.fn(() => new Promise(() => {}))
  await mount([event(93131, 'draft', 2 * HOUR, 'Draft'), event(93132, 'published', 48 * HOUR, 'Visible published')], '/dashboard/scanner', { lookups })
  await waitFor(() => expect(lookups).toHaveBeenCalled())
  expect(screen.getByLabelText('Event to scan')).toHaveValue('')
  expect(apiClient.post).not.toHaveBeenCalled()
  await act(() => vi.advanceTimersByTimeAsync(4000))
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('93132'))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/93132/scanner_devices', expect.anything()))
  const lookupSignal = apiClient.get.mock.calls.find(([, config]) => config?.params?.status === 'published')[1].signal
  expect(lookupSignal.aborted).toBe(true)
})

it('uses a prompt cross-page lookup without waiting for or later applying the deadline', async () => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'], shouldAdvanceTime: true })
  const lookups = vi.fn(async params => params.order === 'starts_at' ? [event(93142, 'published', -1 * HOUR, 'Tonight on page 2')] : [])
  await mount([event(93141, 'published', 48 * HOUR, 'Visible published')], '/dashboard/scanner', { lookups })
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('93142'))
  const lookupSignal = apiClient.get.mock.calls.find(([, config]) => config?.params?.status === 'published')[1].signal
  await act(() => vi.advanceTimersByTimeAsync(4000))
  expect(lookupSignal.aborted).toBe(false)
  expect(screen.getByLabelText('Event to scan')).toHaveValue('93142')
  expect(apiClient.post).not.toHaveBeenCalledWith('/organizer/events/93141/scanner_devices', expect.anything())
})

it('aborts a pending cross-page lookup when the page unmounts', async () => {
  const lookups = vi.fn(() => new Promise(() => {}))
  const { unmount } = await mount([event(93151, 'published', 48 * HOUR)], '/dashboard/scanner', { lookups })
  await waitFor(() => expect(lookups).toHaveBeenCalled())
  const lookupSignal = apiClient.get.mock.calls.find(([, config]) => config?.params?.status === 'published')[1].signal
  unmount()
  expect(lookupSignal.aborted).toBe(true)
  expect(apiClient.post).not.toHaveBeenCalled()
})
