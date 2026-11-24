import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'

vi.mock('@clerk/clerk-react', () => ({ useAuth: () => ({ isLoaded: true, isSignedIn: false }) }))

async function renderAt(path, { demo, clerkKey = '' } = {}) {
  vi.resetModules()
  vi.stubEnv('VITE_HAFAPASS_DEMO_DATA', demo ? '1' : '')
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', clerkKey)
  const { default: ProtectedRoute } = await import('./ProtectedRoute')
  render(<MemoryRouter initialEntries={[path]}><Routes>
    <Route path="/sign-in/*" element={<p>sign in page</p>} />
    <Route path="*" element={<ProtectedRoute><p>private page</p></ProtectedRoute>} />
  </Routes></MemoryRouter>)
}

describe('ProtectedRoute', () => {
  afterEach(() => { vi.unstubAllEnvs(); vi.resetModules() })

  it('demo mode opens staff routes with the demo identity', async () => {
    await renderAt('/dashboard/finances', { demo: true })
    expect(await screen.findByText('private page')).toBeInTheDocument()
  })

  it('demo mode keeps the sign-in-is-off notice on buyer account routes', async () => {
    await renderAt('/my-tickets', { demo: true })
    expect(await screen.findByText('Your tickets in this preview')).toBeInTheDocument()
    expect(screen.queryByText('private page')).not.toBeInTheDocument()
  })

  it('flag off with Clerk configured still sends signed-out visitors to sign in, even on staff routes', async () => {
    await renderAt('/dashboard', { demo: false, clerkKey: 'pk_test_example' })
    expect(await screen.findByText('sign in page')).toBeInTheDocument()
    expect(screen.queryByText('private page')).not.toBeInTheDocument()
  })

  it('flag off without Clerk in development behaves as before', async () => {
    await renderAt('/dashboard', { demo: false })
    expect(await screen.findByText('private page')).toBeInTheDocument()
  })
})
