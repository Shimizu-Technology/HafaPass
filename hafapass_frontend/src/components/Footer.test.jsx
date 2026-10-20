import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import { resetSupportContactForTests } from '../utils/supportContact'
import Footer from './Footer'

vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: (key, values) => (values ? `${key} ${values.phone}` : key) }) }))
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
  expect(screen.getByRole('link', { name: 'footer.contact' })).toHaveAttribute('href', 'mailto:operator@example.test?subject=H%C3%A5faPass%20Support')
})

it('offers ticket recovery and support instead of unrelated social homepages', () => {
  render(<MemoryRouter><Footer /></MemoryRouter>)
  expect(screen.getByRole('link', { name: 'footer.findTickets' })).toHaveAttribute('href', '/orders/recover')
  expect(screen.getByRole('link', { name: 'footer.contactSupport' }).getAttribute('href')).toMatch(/^(?:mailto:|\/orders\/recover$)/)
  for (const name of ['Instagram', 'Facebook', 'X']) {
    expect(screen.queryByRole('link', { name })).not.toBeInTheDocument()
  }
})

it('uses the admin-managed support contact and offers a call link when a phone is set', async () => {
  vi.stubEnv('VITE_SUPPORT_EMAIL', '')
  apiClient.get.mockResolvedValue({ data: { support_email: 'help@example.test', support_phone: '671-555-0100' } })
  render(<MemoryRouter><Footer /></MemoryRouter>)

  expect(await screen.findByRole('link', { name: 'footer.callSupport 671-555-0100' })).toHaveAttribute('href', 'tel:6715550100')
  expect(screen.getByRole('link', { name: 'footer.contactSupport' })).toHaveAttribute('href', 'mailto:help@example.test?subject=H%C3%A5faPass%20Support')
})

it('sends people to in-app ticket help instead of a broken mailto when no contact is configured', () => {
  vi.stubEnv('VITE_SUPPORT_EMAIL', '')
  render(<MemoryRouter><Footer /></MemoryRouter>)
  expect(screen.getByRole('link', { name: 'footer.contactSupport' })).toHaveAttribute('href', '/orders/recover')
  expect(screen.queryByRole('link', { name: /footer.callSupport/ })).not.toBeInTheDocument()
})

it('points organizers to the host landing page with pricing', () => {
  render(<MemoryRouter><Footer /></MemoryRouter>)
  expect(screen.getByRole('link', { name: 'footer.forOrganizers' })).toHaveAttribute('href', '/host')
})
