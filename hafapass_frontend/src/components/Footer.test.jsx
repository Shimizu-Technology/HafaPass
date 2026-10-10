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
