import { HelmetProvider } from 'react-helmet-async'
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterAll, beforeAll, expect, it, vi } from 'vitest'

vi.mock('@clerk/clerk-react', () => ({
  useAuth: () => { throw new Error('Clerk provider is unavailable') },
  SignIn: () => { throw new Error('Clerk provider is unavailable') },
  SignUp: () => { throw new Error('Clerk provider is unavailable') },
}))
let SignInPage
let SignUpPage
beforeAll(async () => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '')
  ;({ default: SignInPage } = await import('./SignInPage'))
  ;({ default: SignUpPage } = await import('./SignUpPage'))
})
afterAll(() => vi.unstubAllEnvs())
it('keeps sign-in unavailable guidance usable without mounting Clerk hooks', async () => {
  render(<HelmetProvider><MemoryRouter><SignInPage /></MemoryRouter></HelmetProvider>)
  await waitFor(() => expect(document.title).toBe('Sign in | HåfaPass'))
  expect(document.querySelector('meta[name="robots"]')).toHaveAttribute('content', 'noindex, nofollow, noarchive')
  expect(screen.getByText('Sign-in is temporarily unavailable. Please try again later.')).toBeInTheDocument()
})
it('keeps sign-up unavailable guidance usable without mounting Clerk hooks', async () => {
  render(<HelmetProvider><MemoryRouter><SignUpPage /></MemoryRouter></HelmetProvider>)
  await waitFor(() => expect(document.title).toBe('Create account | HåfaPass'))
  expect(document.querySelector('meta[name="robots"]')).toHaveAttribute('content', 'noindex, nofollow, noarchive')
  expect(screen.getByText('Account registration is temporarily unavailable. Please try again later.')).toBeInTheDocument()
})
