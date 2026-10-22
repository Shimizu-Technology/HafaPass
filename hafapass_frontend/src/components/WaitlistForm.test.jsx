import { expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import WaitlistForm from './WaitlistForm'

vi.mock('../api/client', () => ({ default: { post: vi.fn(), get: vi.fn(), delete: vi.fn() } }))

it('states the event-specific email request and exit clearly at join', () => {
  render(<WaitlistForm event={{ slug: 'friday-show' }} />)
  expect(screen.getByText("We'll email you if tickets become available for this event. You can stop these alerts anytime.")).toBeInTheDocument()
})
