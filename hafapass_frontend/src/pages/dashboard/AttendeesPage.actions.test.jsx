import { cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
import { saveBlob } from '../../utils/download'
import AttendeesPage from './AttendeesPage'

vi.mock('../../api/client', async original => ({ ...await original(), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../../components/EventWorkspace', () => ({ default: ({ children }) => <div>{children}</div> }))
vi.mock('../../utils/download', () => ({ saveBlob: vi.fn() }))

const baseEvent = { id: 37, organization_id: 1, title: 'Full Moon Party', status: 'published', ticket_types: [] }
const attendees = [
  { id: 7, attendee_name: 'Mina Cruz', attendee_email: 'mina@example.invalid', status: 'issued', ticket_type: 'Entry' },
  { id: 8, attendee_name: 'Jose Santos', attendee_email: 'jose@example.invalid', status: 'checked_in', ticket_type: 'Entry', checked_in_at: '2026-10-20T10:00:00Z' },
  { id: 9, attendee_name: 'Ana Reyes', attendee_email: 'ana@example.invalid', status: 'cancelled', ticket_type: 'Entry' }
]
let clearAuth

function ScannerProbe() {
  const location = useLocation()
  return <p>Scanner at {location.pathname}{location.search}</p>
}

function mount(permissions, event = {}, initialUrl = '/dashboard/events/37/attendees', recentExports = []) {
  apiClient.get.mockImplementation(url => Promise.resolve({ data: url.endsWith('/sales_exports')
    ? { exports: recentExports }
    : url.includes('/attendees') ? { attendees, meta: { total_pages: 1, total_count: attendees.length } }
      : { ...baseEvent, ...event, permissions: { view_attendees: true, ...permissions } } }))
  return render(<MemoryRouter initialEntries={[initialUrl]}><Routes>
    <Route path="/dashboard/events/:id/attendees" element={<AttendeesPage />} />
    <Route path="/dashboard/scanner" element={<ScannerProbe />} />
  </Routes></MemoryRouter>)
}

beforeEach(() => {
  vi.clearAllMocks(); window.localStorage.clear()
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '')
  window.localStorage.setItem('hafapass_scanner_user_id', 'actor-a'); window.localStorage.setItem('hafapass_organization_id', '1')
  clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-token'), { userId: 'actor-a', sessionId: 'session-a', ready: true })
  apiClient.get.mockReset(); apiClient.post.mockReset()
})
afterEach(() => { cleanup(); clearAuth?.(); vi.unstubAllEnvs(); vi.restoreAllMocks() })

describe('attendee row actions', () => {
  it('hides row actions without scan or attendee management permission', async () => {
    mount({})
    await screen.findAllByText('Mina Cruz')
    expect(screen.queryByRole('columnheader', { name: 'Actions' })).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: /Check in/ })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Resend ticket/ })).not.toBeInTheDocument()
  })

  it('offers check-in only to scanners for valid tickets on a published event', async () => {
    mount({ scan: true })
    await screen.findAllByText('Mina Cruz')
    // Desktop table and phone card each render the action.
    expect(screen.getAllByRole('link', { name: 'Check in Mina Cruz' })).toHaveLength(2)
    expect(screen.queryByRole('link', { name: 'Check in Jose Santos' })).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Check in Ana Reyes' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Resend ticket/ })).not.toBeInTheDocument()
  })

  it('hands check-in to the scanner with the ticket pre-selected instead of admitting directly', async () => {
    mount({ scan: true })
    const [link] = await screen.findAllByRole('link', { name: 'Check in Mina Cruz' })
    expect(link).toHaveAttribute('href', '/dashboard/scanner?event=37&lookup=HP-T7')
    await userEvent.click(link)
    expect(await screen.findByText('Scanner at /dashboard/scanner?event=37&lookup=HP-T7')).toBeInTheDocument()
    expect(apiClient.post).not.toHaveBeenCalled()
  })

  it('does not offer check-in before the event is published', async () => {
    mount({ scan: true }, { status: 'draft' })
    await screen.findAllByText('Mina Cruz')
    expect(screen.queryByRole('link', { name: /Check in/ })).not.toBeInTheDocument()
  })

  it('confirms, shows progress and reports a successful resend', async () => {
    let finish
    apiClient.post.mockReturnValue(new Promise(resolve => { finish = resolve }))
    mount({ manage_attendees: true })
    await screen.findAllByText('Mina Cruz')
    expect(screen.queryByRole('button', { name: 'Resend ticket to Ana Reyes' })).not.toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: 'Resend ticket to Jose Santos' })).toHaveLength(2)
    await userEvent.click(screen.getAllByRole('button', { name: 'Resend ticket to Mina Cruz' })[0])
    const dialog = screen.getByRole('dialog', { name: 'Resend ticket email?' })
    expect(apiClient.post).not.toHaveBeenCalled()
    await userEvent.click(within(dialog).getByRole('button', { name: 'Resend ticket' }))
    expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/37/attendees/7/resend', {}, expect.any(Object))
    expect(within(dialog).getByRole('button', { name: /Sending/ })).toBeDisabled()
    finish({ data: { message: 'Ticket email queued', recipient: 'buyer@example.invalid' } })
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
    expect(screen.getByText('Ticket email for Mina Cruz is on its way to buyer@example.invalid.')).toBeInTheDocument()
  })

  it('keeps the confirmation open with the server reason when a resend fails', async () => {
    apiClient.post.mockRejectedValue({ response: { status: 429, data: { error: 'A ticket email was requested recently. Please wait two minutes before requesting another' } } })
    mount({ manage_attendees: true })
    await screen.findAllByText('Mina Cruz')
    await userEvent.click(screen.getAllByRole('button', { name: 'Resend ticket to Mina Cruz' })[0])
    const dialog = screen.getByRole('dialog', { name: 'Resend ticket email?' })
    await userEvent.click(within(dialog).getByRole('button', { name: 'Resend ticket' }))
    expect(await within(dialog).findByRole('alert')).toHaveTextContent('wait two minutes')
    expect(within(dialog).getByRole('button', { name: 'Resend ticket' })).toBeEnabled()
    expect(screen.getAllByText('Mina Cruz').length).toBeGreaterThan(0)
  })

  it.each([403, 404])('keeps the attendee list and explains a resend %s inside the dialog', async status => {
    apiClient.post.mockRejectedValue({ response: { status, data: { error: status === 404 ? 'Attendee not found' : 'You do not have permission to perform this action' } } })
    mount({ manage_attendees: true })
    await screen.findAllByText('Mina Cruz')
    await userEvent.click(screen.getAllByRole('button', { name: 'Resend ticket to Mina Cruz' })[0])
    const dialog = screen.getByRole('dialog', { name: 'Resend ticket email?' })
    await userEvent.click(within(dialog).getByRole('button', { name: 'Resend ticket' }))
    expect(await within(dialog).findByRole('alert')).toHaveTextContent(status === 404 ? 'Attendee not found' : 'do not have permission')
    expect(screen.getAllByText('Jose Santos').length).toBeGreaterThan(0)
    expect(screen.queryByText(/attendee access changed|Event not found/)).not.toBeInTheDocument()
  })

  it('withdraws the page when a resend reports the sign-in expired', async () => {
    apiClient.post.mockRejectedValue({ response: { status: 401, data: { error: 'Unauthorized' } } })
    mount({ manage_attendees: true })
    await screen.findAllByText('Mina Cruz')
    await userEvent.click(screen.getAllByRole('button', { name: 'Resend ticket to Mina Cruz' })[0])
    await userEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Resend ticket' }))
    expect(await screen.findByText('Please sign in.')).toBeInTheDocument()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.queryByText('Mina Cruz')).not.toBeInTheDocument()
  })
})

describe('sales list controls', () => {
  it('limits finance-only users to order-number search and non-name sorts', async () => {
    mount({ view_attendees: false, view_finance: true })
    await screen.findByRole('textbox', { name: 'Search by order #' })
    expect(screen.getByPlaceholderText('Search by order #')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Filters & sort' }))
    expect(within(screen.getByRole('combobox', { name: 'Sort by' })).queryByRole('option', { name: 'Name' })).not.toBeInTheDocument()
  })

  it('restores URL filters, shows chips, and clears them', async () => {
    mount({}, { ticket_types: [{ id: 4, name: 'Entry' }] }, '/dashboard/events/37/attendees?status=checked_in&ticket_type=4')
    await screen.findAllByText('Mina Cruz')
    expect(screen.getByRole('region', { name: 'Active filters' })).toHaveTextContent('Status: Checked in')
    expect(screen.getByRole('region', { name: 'Active filters' })).toHaveTextContent('Ticket type: Entry')
    expect(apiClient.get).toHaveBeenCalledWith(expect.stringContaining('status=checked_in'), expect.any(Object))
    await userEvent.click(screen.getByRole('button', { name: 'Clear filters' }))
    await waitFor(() => expect(screen.queryByRole('region', { name: 'Active filters' })).not.toBeInTheDocument())
  })

  it('shows human filter chips, hides defaults, and keeps machine values in the URL', async () => {
    mount({}, { ticket_types: [{ id: 4, name: 'VIP Front Row' }] }, '/dashboard/events/37/attendees?search=tanaka&ticket_type=4&payment_environment=all&sort=name&direction=asc&purchased_from=2026-10-01&purchased_to=2026-10-15')
    await screen.findAllByText('Mina Cruz')
    const chips = screen.getByRole('region', { name: 'Active filters' })
    for (const label of ['Search: tanaka', 'Ticket type: VIP Front Row', 'Live and test orders', 'Sorted by name (A–Z)', 'Purchased Oct 1 – Oct 15']) {
      expect(within(chips).getByRole('button', { name: `${label} ×` })).toBeInTheDocument()
    }
    expect(apiClient.get).toHaveBeenCalledWith(expect.stringContaining('direction=asc'), expect.any(Object))
    await userEvent.click(within(chips).getByRole('button', { name: 'Sorted by name (A–Z) ×' }))
    expect(within(chips).queryByText(/Sorted by/)).not.toBeInTheDocument()
  })

  it('does not show chips for explicit default filter values', async () => {
    mount({}, {}, '/dashboard/events/37/attendees?view=tickets&payment_environment=live&sort=purchase_date&direction=desc')
    await screen.findAllByText('Mina Cruz')
    expect(screen.queryByRole('region', { name: 'Active filters' })).not.toBeInTheDocument()
  })

  it('uses human status labels for filters and API display labels for rows', async () => {
    mount({}, {}, '/dashboard/events/37/attendees?status=partially_refunded')
    await screen.findAllByText('Mina Cruz')
    expect(screen.getByRole('region', { name: 'Active filters' })).toHaveTextContent('Status: Partially refunded')
    await userEvent.click(screen.getByRole('button', { name: 'Filters & sort' }))
    const select = screen.getByLabelText('Filter attendees by status')
    expect(within(select).getByRole('option', { name: 'Valid' })).toHaveValue('issued')
    expect(within(select).getByRole('option', { name: 'Not checked in' })).toHaveValue('not_checked_in')
    expect(within(select).getByRole('option', { name: 'Partially refunded' })).toHaveValue('partially_refunded')
  })

  it('provides cards for phones and an export dialog with the filtered scope', async () => {
    mount({ view_finance: true })
    await screen.findAllByText('Mina Cruz')
    expect(document.querySelector('.sm\\:hidden')).toHaveTextContent('Mina Cruz')
    await userEvent.click(screen.getByRole('button', { name: 'Export this list' }))
    const dialog = screen.getByRole('dialog', { name: 'Export this list' })
    expect(within(dialog).getByText(/3 attendees match/)).toBeInTheDocument()
    expect(within(dialog).getByRole('checkbox', { name: 'Total paid' })).toBeInTheDocument()
    expect(within(dialog).getByRole('button', { name: 'Download CSV' })).toBeEnabled()
  })

  it('updates the URL when filters change and hides financial export columns from box office', async () => {
    mount({ view_finance: false })
    await screen.findAllByText('Mina Cruz')
    await userEvent.click(screen.getByRole('button', { name: 'Filters & sort' }))
    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Sales channel' }), 'box_office')
    expect(screen.getByRole('button', { name: /Sales channel: Box office/ })).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Show results' }))
    await userEvent.click(screen.getByRole('button', { name: 'Export this list' }))
    expect(screen.queryByRole('checkbox', { name: 'Total paid' })).not.toBeInTheDocument()
    expect(screen.getByRole('checkbox', { name: 'Phone' })).toBeInTheDocument()
  })

  it('shows a follow-up download control for a queued large export', async () => {
    apiClient.post.mockResolvedValue({ status: 202, data: { text: async () => JSON.stringify({ download_url: '/api/v1/organizer/events/37/sales_exports/9' }) } })
    mount({})
    await screen.findAllByText('Mina Cruz')
    await userEvent.click(screen.getByRole('button', { name: 'Export this list' }))
    await userEvent.click(screen.getByRole('button', { name: 'Download CSV' }))
    expect(await screen.findByRole('button', { name: 'Check download' })).toBeInTheDocument()
    apiClient.get.mockImplementation(url => Promise.resolve({ status: 202, data: url.includes('sales_exports/9') ? new Blob(['{"status":"processing"}']) : { ...baseEvent, permissions: { view_attendees: true } } }))
    await userEvent.click(screen.getByRole('button', { name: 'Check download' }))
    expect(apiClient.get).toHaveBeenCalledWith('/organizer/events/37/sales_exports/9', expect.objectContaining({ responseType: 'blob' }))
  })

  it('shows failed exports with a retry action after a denied download', async () => {
    apiClient.post.mockResolvedValue({ status: 202, data: { text: async () => JSON.stringify({ download_url: '/api/v1/organizer/events/37/sales_exports/9' }) } })
    mount({})
    await screen.findAllByText('Mina Cruz')
    await userEvent.click(screen.getByRole('button', { name: 'Export this list' }))
    await userEvent.click(screen.getByRole('button', { name: 'Download CSV' }))
    apiClient.get.mockImplementation(url => url.includes('sales_exports/9')
      ? Promise.reject({ response: { status: 422, data: new Blob(['{"status":"failed"}']) } })
      : Promise.resolve({ data: { ...baseEvent, permissions: { view_attendees: true } } }))
    await userEvent.click(await screen.findByRole('button', { name: 'Check download' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('This export failed — run it again')
    await userEvent.click(screen.getByRole('button', { name: 'Run again' }))
    expect(screen.getByRole('dialog', { name: 'Export this list' })).toBeInTheDocument()
  })

  it('downloads the filtered door list as a printable PDF', async () => {
    mount({})
    await screen.findAllByText('Mina Cruz')
    const pdf = new Blob(['synthetic-pdf'], { type: 'application/pdf' })
    apiClient.get.mockResolvedValueOnce({ data: pdf })
    await userEvent.click(screen.getByRole('button', { name: 'Print door list' }))
    await waitFor(() => expect(saveBlob).toHaveBeenCalledWith(pdf, 'event-37-door-list.pdf'))
  })

  it('shows order totals and check-in counts in the order view', async () => {
    mount({ view_finance: true })
    await screen.findAllByText('Mina Cruz')
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url.includes('/attendees')
      ? { attendees: [{ id: 3, attendee_name: 'Buyer Mina', attendee_email: 'buyer@example.invalid',
        order_number: 'HP-ORDER3', ticket_type: 'Entry', status: 'completed',
        purchase_date: '2026-10-20T10:00:00Z', amount_cents: 5250, ticket_count: 2, checked_in_count: 1 }],
        meta: { total_pages: 1, total_count: 1 } }
      : { ...baseEvent, permissions: { view_attendees: true, view_finance: true } } }))
    await userEvent.click(screen.getByRole('button', { name: 'Filters & sort' }))
    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'View sales as' }), 'orders')
    await userEvent.click(screen.getByRole('button', { name: 'Show results' }))
    expect(await screen.findByRole('heading', { name: 'Sales orders' })).toBeInTheDocument()
    expect(screen.getAllByText('$52.50').length).toBeGreaterThan(0)
    expect(screen.getByText('1/2 checked in')).toBeInTheDocument()
  })
  it('restores an actor-scoped queued export after a page remount', async () => {
    const recent = [{ id: 9, row_count: 12000, status: 'ready',
      download_url: '/api/v1/organizer/events/37/sales_exports/9' }]
    const page = mount({}, {}, '/dashboard/events/37/attendees', recent)
    expect(await screen.findByRole('region', { name: 'Recent exports' })).toHaveTextContent('Export #9')
    page.unmount()
    mount({}, {}, '/dashboard/events/37/attendees', recent)
    expect(await screen.findByRole('region', { name: 'Recent exports' })).toHaveTextContent('ready')
    expect(screen.getByRole('button', { name: 'Download' })).toBeEnabled()
  })

  it('hides attendee columns from finance-only export choices', async () => {
    mount({ view_attendees: false, view_finance: true })
    await screen.findAllByText('Mina Cruz')
    await userEvent.click(screen.getByRole('button', { name: 'Export this list' }))
    const dialog = screen.getByRole('dialog', { name: 'Export this list' })
    expect(within(dialog).queryByRole('checkbox', { name: 'Phone' })).not.toBeInTheDocument()
    expect(within(dialog).queryByRole('checkbox', { name: 'Registration answers' })).not.toBeInTheDocument()
    expect(within(dialog).getByRole('checkbox', { name: 'Total paid' })).toBeInTheDocument()
  })

})
