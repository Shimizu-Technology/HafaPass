import { render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { describe, expect, it } from 'vitest'
import SupportRoute from './SupportRoute'

describe('SupportRoute', () => {
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
