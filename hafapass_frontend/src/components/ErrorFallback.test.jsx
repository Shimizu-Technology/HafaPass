import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import ErrorFallback from './ErrorFallback'

describe('ErrorFallback', () => {
  it('offers a safe recovery action', async () => {
    const user = userEvent.setup()
    const resetError = vi.fn()

    render(<ErrorFallback error={new Error('test failure')} resetError={resetError} />)

    expect(screen.getByRole('heading', { name: /something interrupted this page/i })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /try again/i }))

    expect(resetError).toHaveBeenCalledOnce()
  })
})
