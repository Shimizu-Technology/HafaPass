import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import TestPaymentBadge from './TestPaymentBadge'

describe('TestPaymentBadge', () => {
  it('marks test-mode orders only', () => {
    const { rerender, container } = render(<TestPaymentBadge order={{ test_payment: true }} />)
    expect(screen.getByText('Test')).toHaveTextContent('Test payment')
    rerender(<TestPaymentBadge order={{ test_payment: false }} />)
    expect(container).toBeEmptyDOMElement()
  })
})
