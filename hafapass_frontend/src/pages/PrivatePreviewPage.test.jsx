import { render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import PrivatePreviewPage from './PrivatePreviewPage'

vi.mock('../components/SEO', () => ({ default: () => null }))
afterEach(() => vi.unstubAllEnvs())

it('uses the same configured support mailbox while application services are unavailable', () => {
  vi.stubEnv('VITE_SUPPORT_EMAIL', 'operator@example.test')
  render(<PrivatePreviewPage />)
  expect(screen.getByRole('link', { name: 'Contact support' })).toHaveAttribute('href', 'mailto:operator@example.test?subject=HafaPass%20Support')
})
