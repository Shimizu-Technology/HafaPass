import { render, screen, waitFor } from '@testing-library/react'
import { HelmetProvider } from 'react-helmet-async'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import PolicyPage from './PolicyPage'

vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))

const titles = {
  'buyer-terms': 'Buyer Terms',
  refunds: 'Refund & Cancellation Policy',
  privacy: 'Privacy Policy',
  cookies: 'Cookie Notice',
  accessibility: 'Accessibility Statement',
  'organizer-agreement': 'Organizer Agreement',
}
const policies = Object.fromEntries(Object.entries(titles).map(([key, title]) => [key, {
  title, summary: `${title} summary.`, sections: [{ heading: 'Current practice', body: 'These terms apply now.' }],
}]))

const renderPolicy = key => render(
  <HelmetProvider><MemoryRouter initialEntries={[`/policies/${key}`]}><Routes>
    <Route path="/policies/:policy" element={<PolicyPage />} />
  </Routes></MemoryRouter></HelmetProvider>,
)

describe('public policy pages', () => {
  beforeEach(() => {
    apiClient.get.mockResolvedValue({ data: {
      buyer_terms_version: '2026-10-22', policy_status: 'approved', policy_effective_date: '2026-10-22', policies,
    } })
  })

  it.each(Object.entries(titles))('serves %s with its title, effective date, version, and share metadata', async (key, title) => {
    renderPolicy(key)
    expect(await screen.findByRole('heading', { name: title, level: 1 })).toBeInTheDocument()
    expect(screen.getByText('October 22, 2026')).toHaveAttribute('datetime', '2026-10-22')
    expect(screen.getByText(/Version 2026-10-22/)).toBeInTheDocument()
    expect(screen.queryByText(/draft|counsel|subject to review|not final/i)).not.toBeInTheDocument()
    await waitFor(() => expect(document.title).toBe(`${title} | HåfaPass`))
    expect(document.querySelector('meta[property="og:url"]').content).toMatch(new RegExp(`/policies/${key}$`))
    expect(document.querySelector('link[rel="canonical"]').href).toMatch(new RegExp(`/policies/${key}$`))
    expect(apiClient.get).toHaveBeenCalledWith('/config')
  })

  it('does not present an older draft response as a live policy', async () => {
    apiClient.get.mockResolvedValue({ data: { policy_status: 'draft-pending-legal-review', policies } })
    renderPolicy('buyer-terms')
    expect(await screen.findByRole('heading', { name: 'Policy unavailable' })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'Buyer Terms' })).not.toBeInTheDocument()
  })
})
