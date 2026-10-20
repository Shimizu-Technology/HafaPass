import { act, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import { resetSupportContactForTests } from '../utils/supportContact'
import SupportLink from './SupportLink'

vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))

beforeEach(() => {
  window.localStorage.clear()
  resetSupportContactForTests()
  apiClient.get.mockReset()
  vi.stubEnv('VITE_SUPPORT_EMAIL', '')
})
afterEach(() => vi.unstubAllEnvs())

function pendingConfig() {
  let resolve
  apiClient.get.mockReturnValue(new Promise(done => { resolve = done }))
  return data => act(async () => { resolve({ data }) })
}

it('appears with the configured mailbox once /config resolves on a first visit with no cache', async () => {
  const resolveConfig = pendingConfig()
  render(<SupportLink subject="Payout setup">Contact support</SupportLink>)
  expect(screen.queryByRole('link', { name: 'Contact support' })).not.toBeInTheDocument()

  await resolveConfig({ support_email: 'help@example.test' })

  expect(screen.getByRole('link', { name: 'Contact support' })).toHaveAttribute('href', 'mailto:help@example.test?subject=Payout%20setup')
})

it('moves a buyer link from its fallback to the mailbox when /config resolves', async () => {
  const resolveConfig = pendingConfig()
  render(<SupportLink subject="Ticket email" fallbackHref="/orders/recover">Contact support</SupportLink>)
  expect(screen.getByRole('link', { name: 'Contact support' })).toHaveAttribute('href', '/orders/recover')

  await resolveConfig({ support_email: 'help@example.test' })

  expect(screen.getByRole('link', { name: 'Contact support' })).toHaveAttribute('href', 'mailto:help@example.test?subject=Ticket%20email')
})

it('stays hidden in organizer contexts when no contact is configured', async () => {
  const resolveConfig = pendingConfig()
  render(<SupportLink subject="Refund review">Contact support</SupportLink>)
  await resolveConfig({ support_email: null })
  expect(screen.queryByRole('link')).not.toBeInTheDocument()
})
