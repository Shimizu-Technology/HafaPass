import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Link, MemoryRouter, Route, Routes } from 'react-router-dom'

vi.mock('posthog-js', () => ({
  default: {
    init: vi.fn(),
    capture: vi.fn(),
  },
}))

import posthog from 'posthog-js'
import { PostHogPageView, PostHogProvider } from './PostHogProvider'
import { resetPostHogStateForTests } from '../utils/posthog'

function TestApp({ initialEntries = ['/events'] }) {
  return (
    <MemoryRouter initialEntries={initialEntries}>
      <PostHogProvider>
        <PostHogPageView />
        <nav>
          <Link to="/checkout/island-fest?payment_intent_client_secret=pi_sec&event=7">Go to checkout</Link>
          <Link to="/tickets/secret-ticket-token?email=buyer@example.com">Go to ticket</Link>
        </nav>
        <Routes>
          <Route path="/events" element={<h1>Events</h1>} />
          <Route path="/checkout/:slug" element={<h1>Checkout</h1>} />
          <Route path="/tickets/:credential" element={<h1>Ticket</h1>} />
        </Routes>
      </PostHogProvider>
    </MemoryRouter>
  )
}

beforeEach(() => {
  vi.clearAllMocks()
  resetPostHogStateForTests()
})

afterEach(() => {
  vi.unstubAllEnvs()
  resetPostHogStateForTests()
})

describe('PostHogProvider and PostHogPageView', () => {
  it('does not initialize or capture pageviews when VITE_PUBLIC_POSTHOG_KEY is missing', () => {
    vi.stubEnv('VITE_PUBLIC_POSTHOG_KEY', '')
    vi.stubEnv('VITE_ENABLE_ANALYTICS_IN_DEV', 'true')

    render(<TestApp initialEntries={['/events']} />)

    expect(screen.getByRole('heading', { name: 'Events' })).toBeInTheDocument()
    expect(posthog.init).not.toHaveBeenCalled()
    expect(posthog.capture).not.toHaveBeenCalled()
  })

  it('initializes PostHog and captures redacted SPA pageviews across navigations', async () => {
    const user = userEvent.setup()
    vi.stubEnv('VITE_PUBLIC_POSTHOG_KEY', 'phc_RealAnalyticsKey987654')
    vi.stubEnv('VITE_ENABLE_ANALYTICS_IN_DEV', 'true')

    render(<TestApp initialEntries={['/events?token=secret_1&category=music']} />)

    expect(posthog.init).toHaveBeenCalledTimes(1)
    expect(posthog.capture).toHaveBeenCalledTimes(1)
    expect(posthog.capture).toHaveBeenLastCalledWith('$pageview', {
      $current_url: `${window.location.origin}/events?category=music`,
    })

    await user.click(screen.getByRole('link', { name: 'Go to checkout' }))

    expect(screen.getByRole('heading', { name: 'Checkout' })).toBeInTheDocument()
    expect(posthog.capture).toHaveBeenCalledTimes(2)
    expect(posthog.capture).toHaveBeenLastCalledWith('$pageview', {
      $current_url: `${window.location.origin}/checkout/island-fest?event=7`,
    })

    await user.click(screen.getByRole('link', { name: 'Go to ticket' }))

    expect(screen.getByRole('heading', { name: 'Ticket' })).toBeInTheDocument()
    expect(posthog.capture).toHaveBeenCalledTimes(3)
    expect(posthog.capture).toHaveBeenLastCalledWith('$pageview', {
      $current_url: `${window.location.origin}/tickets/[redacted]`,
    })
  })
})
