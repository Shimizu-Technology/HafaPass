import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, expect, it, vi } from 'vitest'
import WaitlistPage from './WaitlistPage'
import apiClient from '../../api/client'

const organizerRequests = vi.hoisted(() => ({
  current: () => true,
  beginRequest: () => ({ controller: new AbortController(), config: {}, current: () => true, release: () => {} }),
}))

vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn(), delete: vi.fn() } }))
vi.mock('../../components/EventWorkspace', () => ({ default: ({ children }) => <div>{children}</div> }))
vi.mock('../../hooks/useOrganizerContext', () => ({
  useOrganizerIdentity: () => ({ ready: true, owner: 'organizer', organizationId: '3', accountKey: 'organizer', authContext: null }),
  useOrganizerPageVisit: () => ({ active: true, generation: 0 }),
  useOrganizerRequests: () => organizerRequests,
}))

beforeEach(() => {
  vi.clearAllMocks()
  window.sessionStorage.clear()
  apiClient.get.mockImplementation(url => Promise.resolve({ data: url.endsWith('/waitlist')
    ? { waitlist: [{ id: 4, name: 'Buyer', email: 'buyer@example.com', status: 'waiting', position: 1,
      quantity: 1, created_at: '2026-10-22T00:00:00Z', withdrawn_offer_delivered: true }],
    stats: { total_waiting: 1 }, marketing_address_ready: true }
    : { id: 7, title: 'Reef Night', permissions: { manage_attendees: true } } }))
  apiClient.post.mockResolvedValue({ data: { offer: { id: 5 } } })
})

it('reissues a withdrawn delivered offer with one click', async () => {
  render(<MemoryRouter initialEntries={['/dashboard/events/7/waitlist']}><Routes>
    <Route path="/dashboard/events/:id/waitlist" element={<WaitlistPage />} />
  </Routes></MemoryRouter>)

  await userEvent.setup().click(await screen.findByRole('button', { name: 'Reissue offer' }))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/7/waitlist/4/offer', {}, expect.any(Object)))
  expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
})
