import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import { resetSupportContactForTests } from '../utils/supportContact'
import Footer from './Footer'

vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))
beforeEach(() => {
  window.localStorage.clear()
  resetSupportContactForTests()
  apiClient.get.mockRejectedValue(new Error('offline'))
})
afterEach(() => vi.unstubAllEnvs())

it('routes the footer contact to the configured receiving mailbox', () => {
  vi.stubEnv('VITE_SUPPORT_EMAIL', 'operator@example.test')
  render(<MemoryRouter><Footer /></MemoryRouter>)
  expect(screen.getByRole('link', { name: "Contact" })).toHaveAttribute('href', 'mailto:operator@example.test?subject=H%C3%A5faPass%20Support')
})

it('offers ticket recovery and support instead of unrelated social homepages', () => {
  render(<MemoryRouter><Footer /></MemoryRouter>)
  expect(screen.getByRole('link', { name: "Find your tickets" })).toHaveAttribute('href', '/orders/recover')
  expect(screen.getByRole('link', { name: "Contact support" }).getAttribute('href')).toMatch(/^(?:mailto:|\/orders\/recover$)/)
  for (const name of ['Instagram', 'Facebook', 'X']) {
    expect(screen.queryByRole('link', { name })).not.toBeInTheDocument()
  }
})

it('uses the admin-managed support contact and offers a call link when a phone is set', async () => {
  vi.stubEnv('VITE_SUPPORT_EMAIL', '')
  apiClient.get.mockResolvedValue({ data: { support_email: 'help@example.test', support_phone: '671-555-0100' } })
  render(<MemoryRouter><Footer /></MemoryRouter>)

  expect(await screen.findByRole('link', { name: 'Call 671-555-0100' })).toHaveAttribute('href', 'tel:6715550100')
  expect(screen.getByRole('link', { name: "Contact support" })).toHaveAttribute('href', 'mailto:help@example.test?subject=H%C3%A5faPass%20Support')
})

it('sends people to in-app ticket help instead of a broken mailto when no contact is configured', () => {
  vi.stubEnv('VITE_SUPPORT_EMAIL', '')
  render(<MemoryRouter><Footer /></MemoryRouter>)
  expect(screen.getByRole('link', { name: "Contact support" })).toHaveAttribute('href', '/orders/recover')
  expect(screen.queryByRole('link', { name: /^Call / })).not.toBeInTheDocument()
})

it('points organizers to the host landing page with pricing', () => {
  render(<MemoryRouter><Footer /></MemoryRouter>)
  expect(screen.getByRole('link', { name: "For Organizers" })).toHaveAttribute('href', '/host')
  screen.getAllByRole('link', { name: 'Organizer Agreement' }).forEach(link => expect(link).toHaveAttribute('href', '/policies/organizer-agreement'))
})


it('keeps every existing navigation link and hides photo credits without credited photos', () => {
  render(<MemoryRouter><Footer /></MemoryRouter>)
  for (const path of ['/events', '/host', '/sign-in', '/orders/recover', '/policies/privacy', '/policies/buyer-terms', '/policies/refunds', '/policies/organizer-agreement', '/policies/accessibility', '/policies/cookies']) {
    expect(document.querySelector(`footer a[href="${path}"]`)).not.toBeNull()
  }
  expect(screen.queryByText('Photo credits')).not.toBeInTheDocument()
})
