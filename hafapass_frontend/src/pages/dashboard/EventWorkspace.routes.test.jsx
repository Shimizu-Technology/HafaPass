import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import GuestListPage from './GuestListPage'
import PromoCodesPage from './PromoCodesPage'

vi.mock('../../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn() } }))
vi.mock('../../hooks/useLaunchCapabilities', () => ({ default: () => ({}) }))
const event = { id: 37, organization_id: 1, title: 'Synthetic Guam reception', status: 'draft',
  starts_at: '2026-11-20T09:00:00Z', timezone: 'Pacific/Guam', venue_name: 'Reception venue', ticket_types: [],
  permissions: { edit_event_content: true, manage_attendees: true, manage_marketing: true } }
beforeEach(() => {
  vi.clearAllMocks(); window.localStorage.clear(); window.localStorage.setItem('hafapass_organization_id', '1')
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path === '/organizer/organizations'
    ? [{ id: 1, name: 'Synthetic event organizer' }] : path.endsWith('/37') ? event : [] }))
})
it('keeps event identity and organization while moving between actual guest-list and promo pages', async () => {
  render(<MemoryRouter initialEntries={['/dashboard/events/37/guest-list']}><Routes>
    <Route path="/dashboard/events/:id/guest-list" element={<GuestListPage />} />
    <Route path="/dashboard/events/:id/promo-codes" element={<PromoCodesPage />} />
  </Routes></MemoryRouter>)
  await screen.findByRole('heading', { name: 'Synthetic Guam reception', level: 1 })
  expect(await screen.findByText('Synthetic event organizer')).toBeInTheDocument()
  expect(screen.getByRole('link', { name: 'Guest list' })).toHaveAttribute('aria-current', 'page')
  await userEvent.click(screen.getByRole('link', { name: 'Promo codes' }))
  await screen.findByRole('heading', { name: 'Promo Codes', level: 2 })
  await screen.findByRole('heading', { name: 'Synthetic Guam reception', level: 1 })
  expect(screen.getByText('Synthetic event organizer')).toBeInTheDocument()
  expect(screen.getByRole('link', { name: 'Promo codes' })).toHaveAttribute('aria-current', 'page')
  expect(screen.getByRole('link', { name: 'Guest list' })).toHaveAttribute('href', '/dashboard/events/37/guest-list')
})
