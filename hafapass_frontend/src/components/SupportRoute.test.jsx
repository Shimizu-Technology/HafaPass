import { render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { useLocation } from 'react-router-dom'
import apiClient from '../api/client'
import SupportRoute from './SupportRoute'

const auth = vi.hoisted(() => ({ isLoaded: true, isSignedIn: false }))
vi.mock('@clerk/clerk-react', () => ({ useAuth: () => auth }))
vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))
function Destination() { const location = useLocation(); return <p>{location.pathname}{location.search}</p> }

describe('SupportRoute', () => {
  beforeEach(() => { vi.clearAllMocks(); auth.isLoaded = true; auth.isSignedIn = false })
  it('redirects signed-out users immediately with their exact protected destination', async () => {
    render(<MemoryRouter initialEntries={['/support?query=HP-123']}><Routes>
      <Route path="/support" element={<SupportRoute clerkConfigured><p>Private support</p></SupportRoute>} />
      <Route path="/sign-in" element={<Destination />} />
    </Routes></MemoryRouter>)
    expect(await screen.findByText('/sign-in?returnTo=%2Fsupport%3Fquery%3DHP-123')).toBeInTheDocument()
    expect(apiClient.get).not.toHaveBeenCalled()
  })
  it('shows a retryable access error when role verification is unavailable', async () => {
    auth.isSignedIn = true
    apiClient.get.mockRejectedValue(new Error('outage'))
    render(<MemoryRouter><SupportRoute clerkConfigured><p>Private support</p></SupportRoute></MemoryRouter>)
    expect(await screen.findByRole('alert')).toHaveTextContent('could not verify')
    expect(screen.queryByText('Private support')).not.toBeInTheDocument()
  })

  it('fails closed when Clerk is not configured', async () => {
    render(
      <MemoryRouter initialEntries={['/support']}>
        <Routes>
          <Route path="/support" element={<SupportRoute clerkConfigured={false}><p>Private support data</p></SupportRoute>} />
          <Route path="/sign-in" element={<p>Sign in required</p>} />
        </Routes>
      </MemoryRouter>,
    )

    expect(await screen.findByText('Sign in required')).toBeInTheDocument()
    expect(screen.queryByText('Private support data')).not.toBeInTheDocument()
  })
})
