import { cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
import AttendeesPage from './AttendeesPage'

vi.mock('../../api/client', async original => ({ ...await original(), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../../components/EventWorkspace', () => ({ default: ({ children }) => <div>{children}</div> }))

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

function mount(permissions, event = {}) {
  apiClient.get.mockImplementation(url => Promise.resolve({ data: url.includes('/attendees')
    ? { attendees, meta: { total_pages: 1, total_count: attendees.length } }
    : { ...baseEvent, ...event, permissions: { view_attendees: true, ...permissions } } }))
  return render(<MemoryRouter initialEntries={['/dashboard/events/37/attendees']}><Routes>
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
})
