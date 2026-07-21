import { render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import AdminRoute from './AdminRoute'

const authState = vi.hoisted(() => ({ isLoaded: true, isSignedIn: false }))

vi.mock('@clerk/clerk-react', () => ({
  useAuth: () => authState,
}))

describe('AdminRoute', () => {
  beforeEach(() => {
    authState.isLoaded = true
    authState.isSignedIn = false
  })

  it('redirects a loaded signed-out visitor instead of leaving an indefinite role spinner', async () => {
    render(
      <MemoryRouter initialEntries={['/admin/events']}>
        <Routes>
          <Route path="/sign-in" element={<h1>Sign in</h1>} />
          <Route
            path="/admin/events"
            element={<AdminRoute clerkConfigured><h1>Admin events</h1></AdminRoute>}
          />
        </Routes>
      </MemoryRouter>,
    )

    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
  })
})
