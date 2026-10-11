import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../api/client'
import AdminUsersPage from '../pages/admin/AdminUsersPage'
import AdminEventsPage from '../pages/admin/AdminEventsPage'
import PaymentReadinessReviewDialog from '../components/PaymentReadinessReviewDialog'
import { getAdminAuthority, withdrawAdminAuthority } from './usePlatformContext'

vi.mock('../api/client', async original => ({ ...await original(), default: { get: vi.fn(), patch: vi.fn(), post: vi.fn() } }))
vi.mock('../pages/admin/AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))
const denial = status => ({ response: { status, data: { error: status === 403 ? 'Admin access required' : 'Unauthorized' } } })
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }
const user = { id: 7, email: 'private@example.invalid', first_name: 'Private', last_name: 'User', role: 'attendee', orders_count: 0, created_at: '2026-10-01' }
let clearAuth
const bind = sessionId => { clearAuth = setAuthTokenGetter(() => Promise.resolve('fixture-token'), { userId: 'admin-a', sessionId, ready: true }) }
beforeEach(() => { vi.clearAllMocks(); apiClient.get.mockReset(); apiClient.patch.mockReset(); apiClient.post.mockReset(); bind('session-a') })
afterEach(() => { cleanup(); clearAuth?.() })
const showUsers = () => render(<MemoryRouter initialEntries={['/admin/users']}><AdminUsersPage /></MemoryRouter>)
const role = () => screen.getAllByRole('combobox', { name: 'Role for private@example.invalid' })[0]

describe('administrator role withdrawal and authoritative recovery', () => {
  it.each([401, 403])('purges private users after current role-update denial %s and only reloads after verified admin retry', async status => {
    apiClient.get.mockImplementation(path => Promise.resolve({ data: path === '/me'
      ? { role: 'admin', clerk_id: 'admin-a' } : { users: [user], meta: {} } }))
    apiClient.patch.mockRejectedValue(denial(status))
    showUsers(); await screen.findAllByText('private@example.invalid')
    fireEvent.change(role(), { target: { value: 'organizer' } })
    await screen.findByRole('button', { name: 'Retry administrator access' })
    expect(screen.queryByText('private@example.invalid')).not.toBeInTheDocument()
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Retry administrator access' }))
    await screen.findAllByText('private@example.invalid')
    expect(apiClient.get.mock.calls.map(([path]) => path)).toEqual(['/admin/users', '/me', '/admin/users'])
    expect(apiClient.patch).toHaveBeenCalledTimes(1)
  })
  it.each([['attendee', 'admin-a'], ['admin', 'different-actor']])('does not restore private records for authoritative role %s and actor %s', async (verifiedRole, clerk_id) => {
    apiClient.get.mockResolvedValueOnce({ data: { users: [user], meta: {} } }).mockResolvedValue({ data: { role: verifiedRole, clerk_id } })
    apiClient.patch.mockRejectedValue(denial(403))
    showUsers(); await screen.findAllByText('private@example.invalid')
    fireEvent.change(role(), { target: { value: 'organizer' } })
    fireEvent.click(await screen.findByRole('button', { name: 'Retry administrator access' }))
    await screen.findByText(/Administrator access has not been restored/)
    expect(screen.queryByText('private@example.invalid')).not.toBeInTheDocument()
    expect(apiClient.get).toHaveBeenCalledTimes(2)
  })
  it.each([403, 503])('retains authorized user data for an ordinary business/network rejection %s', async status => {
    apiClient.get.mockResolvedValue({ data: { users: [user], meta: {} } })
    apiClient.patch.mockRejectedValue({ response: { status, data: { error: status === 403 ? 'Cannot modify your own role' : 'Temporary outage' } } })
    showUsers(); await screen.findAllByText('private@example.invalid')
    fireEvent.change(role(), { target: { value: 'organizer' } })
    await screen.findByRole('alert')
    expect(screen.getAllByText('private@example.invalid').length).toBeGreaterThan(0)
    expect(role()).toBeEnabled()
    expect(screen.queryByRole('button', { name: 'Retry administrator access' })).not.toBeInTheDocument()
  })
  it('ignores an old-session denial after a newer admin has loaded', async () => {
    const old = deferred()
    apiClient.get.mockResolvedValue({ data: { users: [user], meta: {} } }); apiClient.patch.mockReturnValue(old.promise)
    showUsers(); await screen.findAllByText('private@example.invalid')
    fireEvent.change(role(), { target: { value: 'organizer' } })
    const config = apiClient.patch.mock.calls[0][2]
    await act(async () => bind('session-b'))
    await screen.findAllByText('private@example.invalid')
    await act(async () => old.reject(denial(403)))
    expect(role()).toBeEnabled(); expect(config.signal.aborted).toBe(true)
    expect(screen.queryByRole('button', { name: 'Retry administrator access' })).not.toBeInTheDocument()
  })
  it('withdraws the events list and open review after a current featured mutation denial', async () => {
    const event = { id: 42, slug: 'private-event', title: 'Private event', status: 'draft', category: 'other', tickets_sold: 0, revenue_cents: 0, is_featured: false }
    apiClient.get.mockResolvedValue({ data: { events: [event], meta: {} } }); apiClient.patch.mockRejectedValue(denial(403))
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)
    fireEvent.click(await screen.findByRole('button', { name: 'Feature Private event' }))
    await screen.findByRole('button', { name: 'Retry administrator access' })
    expect(screen.queryByText('Private event')).not.toBeInTheDocument()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })
  it('synchronously aborts a queued page request when another admin scope loses authority', async () => {
    const read = deferred(); apiClient.get.mockReturnValue(read.promise)
    showUsers(); await waitFor(() => expect(apiClient.get).toHaveBeenCalled())
    const config = apiClient.get.mock.calls[0][1]; const authority = getAdminAuthority()
    await act(async () => withdrawAdminAuthority(denial(403), authority.authContext, authority.generation))
    expect(config.signal.aborted).toBe(true)
    await act(async () => read.resolve({ data: { users: [user], meta: {} } }))
    expect(screen.queryByText('private@example.invalid')).not.toBeInTheDocument()
  })
  it('closes a payment evidence dialog on role loss and does not replay a decision after retry', async () => {
    const account = { id: 11, provider: 'stripe', readiness_submission: { id: 91, actor_user_id: 7, evidence_reference: 'private-evidence', controls: {} } }
    apiClient.patch.mockRejectedValue(denial(403)); apiClient.get.mockResolvedValue({ data: { role: 'admin', clerk_id: 'admin-a' } })
    render(<PaymentReadinessReviewDialog account={account} onComplete={vi.fn()} />)
    fireEvent.click(screen.getByRole('button', { name: 'Review pending evidence' }))
    expect(screen.getByText('private-evidence')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Approve exact evidence' }))
    await screen.findByRole('button', { name: 'Retry administrator access' })
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.queryByText('private-evidence')).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Retry administrator access' }))
    await screen.findByRole('button', { name: 'Review pending evidence' })
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(apiClient.patch).toHaveBeenCalledTimes(1)
  })
})
