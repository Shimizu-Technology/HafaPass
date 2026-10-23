import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import EventStaffPage from './EventStaffPage'

vi.mock('../../api/client', async original => ({ ...(await original()), default: { get: vi.fn(), post: vi.fn(), delete: vi.fn() } }))
vi.mock('../../components/EventWorkspace', () => ({ default: ({ children }) => <div>{children}</div> }))

const event = { id: 11, organization_id: 1, title: 'Night Market', permissions: { manage_staff: true } }
let staff
const show = () => render(<MemoryRouter initialEntries={['/dashboard/events/11/team']}>
  <Routes><Route path="/dashboard/events/:id/team" element={<EventStaffPage />} /></Routes>
</MemoryRouter>)

describe('EventStaffPage one-step invitations', () => {
  beforeEach(() => {
    vi.clearAllMocks(); window.localStorage.clear(); window.sessionStorage.clear()
    window.localStorage.setItem('hafapass_organization_id', '1')
    staff = { assignments: [], candidates: [], pending_invitations: [] }
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url.endsWith('/staff_assignments') ? staff : event }))
  })

  it('invites door staff by email with a described role and shows them as waiting', async () => {
    apiClient.post.mockResolvedValue({ data: { invitation: {
      membership_id: 5, email: 'door@example.com', role: 'scanner', invitation_status: 'pending',
      email_delivery: { status: 'queued', provider: 'resend' }, invitation_token: 'door-token',
    } } })
    show()
    await screen.findByRole('heading', { name: 'Invite door staff by email' })
    expect(screen.getByRole('radio', { name: /Door scanner.*Scans tickets at assigned events only/ })).toBeChecked()
    expect(screen.getByRole('radio', { name: /Box office.*Door sales and fixes/ })).toBeInTheDocument()
    expect(screen.queryByRole('radio', { name: /Manager/ })).not.toBeInTheDocument()

    await userEvent.type(screen.getByLabelText('Email'), 'door@example.com')
    await userEvent.click(screen.getByRole('button', { name: 'Send invitation' }))

    expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/11/staff_assignments', { email: 'door@example.com', role: 'scanner' }, expect.anything())
    await screen.findByText(/They can work this event as Door scanner as soon as they accept/)
    const waiting = within(screen.getByRole('region', { name: 'Waiting to accept' }))
    expect(waiting.getByText('door@example.com')).toBeInTheDocument()
    expect(screen.getByLabelText('Invitation link').value).toContain('door-token')
  })

  it('assigns someone already on the team straight away', async () => {
    apiClient.post.mockResolvedValue({ data: { assignment: { id: 9, email: 'staff@example.com', role: 'box_office', status: 'active' } } })
    show()
    await screen.findByRole('heading', { name: 'Invite door staff by email' })
    await userEvent.type(screen.getByLabelText('Email'), 'staff@example.com')
    await userEvent.click(screen.getByRole('radio', { name: /Box office/ }))
    await userEvent.click(screen.getByRole('button', { name: 'Send invitation' }))
    await screen.findByText(/already on your team and can now work this event as Box office/)
    expect(screen.queryByLabelText('Invitation link')).not.toBeInTheDocument()
  })

  it('withdraws a pending invitation for this event', async () => {
    staff.pending_invitations = [{ membership_id: 5, email: 'door@example.com', role: 'scanner', invitation_status: 'expired' }]
    apiClient.delete.mockResolvedValue({})
    show()
    expect(await screen.findByText('Invite expired')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Withdraw invitation for door@example.com' }))
    expect(apiClient.delete).toHaveBeenCalledWith('/organizer/events/11/staff_invitations/5', expect.anything())
    await screen.findByText(/removed from this event’s invitations/)
  })

  it('shows a calm access state to people who cannot manage staff', async () => {
    apiClient.get.mockResolvedValue({ data: { ...event, permissions: { scan: true } } })
    show()
    expect(await screen.findByText(/Ask your organization owner if you need it/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Send invitation' })).not.toBeInTheDocument()
  })
  it('shows ended assignment access and the offline revocation window', async () => {
    staff.assignments = [{ id: 1, email: 'expired@example.com', role: 'scanner', status: 'active', expires_at: '2025-01-01T00:00:00Z' }]
    show()
    expect(await screen.findByText('Access ended Jan 1, 10:00 AM Guam time')).toBeInTheDocument()
    expect(screen.getByText('Door scanner · Access ended')).toBeInTheDocument()
    expect(screen.getByText(/Scanner phones that are offline keep working/)).toBeInTheDocument()
  })

})
