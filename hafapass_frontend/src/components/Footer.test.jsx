import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, expect, it, vi } from 'vitest'
import Footer from './Footer'

vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: key => key }) }))
afterEach(() => vi.unstubAllEnvs())

it('routes the footer contact to the configured receiving mailbox', () => {
  vi.stubEnv('VITE_SUPPORT_EMAIL', 'operator@example.test')
  render(<MemoryRouter><Footer /></MemoryRouter>)
  expect(screen.getByRole('link', { name: 'footer.contact' })).toHaveAttribute('href', 'mailto:operator@example.test?subject=HafaPass%20Support')
})

it('offers ticket recovery and support instead of unrelated social homepages', () => {
  render(<MemoryRouter><Footer /></MemoryRouter>)
  expect(screen.getByRole('link', { name: 'footer.findTickets' })).toHaveAttribute('href', '/orders/recover')
  expect(screen.getByRole('link', { name: 'footer.contactSupport' }).getAttribute('href')).toMatch(/^mailto:/)
  for (const name of ['Instagram', 'Facebook', 'X']) {
    expect(screen.queryByRole('link', { name })).not.toBeInTheDocument()
  }
})
