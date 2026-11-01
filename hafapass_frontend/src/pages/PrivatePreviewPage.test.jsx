import { render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import PrivatePreviewPage from './PrivatePreviewPage'
import SEO from '../components/SEO'

vi.mock('../components/SEO', () => ({ default: vi.fn(() => null) }))
afterEach(() => vi.unstubAllEnvs())

it('uses the same configured support mailbox while application services are unavailable', () => {
  vi.stubEnv('VITE_SUPPORT_EMAIL', 'operator@example.test')
  render(<PrivatePreviewPage />)
  expect(screen.getByRole('link', { name: 'Contact support' })).toHaveAttribute('href', 'mailto:operator@example.test?subject=H%C3%A5faPass%20Support')
})

it('stays out of indexes so a private ticket or unsubscribe URL never becomes canonical', () => {
  render(<PrivatePreviewPage />)
  expect(SEO.mock.calls.at(-1)[0]).toMatchObject({ noIndex: true })
})
