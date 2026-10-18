import { render, screen } from '@testing-library/react'
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
it('keeps sign-in unavailable guidance usable without mounting Clerk hooks', () => {
  render(<MemoryRouter><SignInPage /></MemoryRouter>)
  expect(screen.getByText('Sign-in is temporarily unavailable. Please try again later.')).toBeInTheDocument()
})
it('keeps sign-up unavailable guidance usable without mounting Clerk hooks', () => {
  render(<MemoryRouter><SignUpPage /></MemoryRouter>)
  expect(screen.getByText('Account registration is temporarily unavailable. Please try again later.')).toBeInTheDocument()
})
