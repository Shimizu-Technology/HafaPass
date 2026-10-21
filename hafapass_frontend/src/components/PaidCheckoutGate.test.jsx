import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import PaidCheckoutGate from './PaidCheckoutGate'

const role = vi.hoisted(() => ({ value: null }))
vi.mock('../utils/workspace', () => ({ useAccountRole: () => role.value }))

describe('PaidCheckoutGate', () => {
  it('lets platform admins through and tells everyone else paid sales open soon', () => {
    const { rerender } = render(<PaidCheckoutGate active><button type="button">Buy</button></PaidCheckoutGate>)
    expect(screen.getByRole('status')).toHaveTextContent('Paid ticket sales open soon')
    expect(screen.queryByRole('button', { name: 'Buy' })).not.toBeInTheDocument()
    role.value = 'admin'
    rerender(<PaidCheckoutGate active><button type="button">Buy</button></PaidCheckoutGate>)
    expect(screen.getByRole('button', { name: 'Buy' })).toBeInTheDocument()
    role.value = null
    rerender(<PaidCheckoutGate active={false}><button type="button">Buy</button></PaidCheckoutGate>)
    expect(screen.getByRole('button', { name: 'Buy' })).toBeInTheDocument()
  })
})
