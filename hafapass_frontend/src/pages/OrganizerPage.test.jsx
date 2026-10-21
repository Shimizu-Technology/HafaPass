import { render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import OrganizerPage from './OrganizerPage'

vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))
vi.mock('../components/SEO', () => ({ default: () => null }))

describe('organizer logo approval', () => {
  beforeEach(() => vi.clearAllMocks())

  it.each([
    ['approved host', 'https://storage.invalid/uploads/logo.webp', 'storage.invalid', true],
    ['off-host URL', 'https://off-host.invalid/uploads/logo.webp', 'storage.invalid', false],
    ['null host', 'https://storage.invalid/uploads/logo.webp', null, false],
  ])('renders the logo only for an %s', async (_case, logo, host, visible) => {
    apiClient.get.mockResolvedValue({ data: { name: 'Island events', slug: 'island', logo_url: logo,
      image_asset_host: host, completed_events: 0, tickets_issued: 0, followers: 0,
      events: [], meta: { current_page: 1, total_pages: 1 } } })
    const view = render(<MemoryRouter initialEntries={['/organizers/island']}><Routes>
      <Route path="/organizers/:slug" element={<OrganizerPage />} />
    </Routes></MemoryRouter>)
    await screen.findByRole('heading', { name: 'Island events' })
    // A null host intentionally hides all remote logos until storage is configured.
    expect(view.container.querySelector('img') !== null).toBe(visible)
  })
})
