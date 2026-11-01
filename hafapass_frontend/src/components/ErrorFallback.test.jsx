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

  it('shows the branded ticket with reload and a plain link home', () => {
    const { container } = render(<ErrorFallback error={new Error('test failure')} resetError={vi.fn()} />)
    expect(screen.getByRole('main')).toHaveClass('bg-brand-950')
    expect(container.querySelector('.ticket-top')).toContainElement(screen.getByRole('heading'))
    expect(screen.getByRole('button', { name: /try again/i })).toHaveClass('btn-primary')
    expect(screen.getByRole('button', { name: 'Reload HåfaPass' })).toHaveClass('btn-secondary')
    expect(screen.getByRole('link', { name: 'Go to the home page' })).toHaveAttribute('href', '/')
    expect(container.innerHTML).not.toMatch(/blur|backdrop/)
  })
})
