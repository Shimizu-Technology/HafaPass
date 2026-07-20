import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { useBackendAvailability } from './hooks/useBackendAvailability'
import ServiceCheck from './ServiceCheck'

vi.mock('./hooks/useBackendAvailability', () => ({
  useBackendAvailability: vi.fn(),
}))

vi.mock('./components/ClerkProviderWrapper', () => ({
  default: ({ children }) => <div data-testid="clerk-provider">{children}</div>,
}))

vi.mock('./App', () => ({
  default: () => <div>Public application</div>,
}))

vi.mock('./pages/PrivatePreviewPage', () => ({
  default: ({ onRetry }) => <button type="button" onClick={onRetry}>Check services again</button>,
}))

describe('ServiceCheck', () => {
  const retry = vi.fn()

  beforeEach(() => {
    retry.mockReset()
  })

  it('shows a service check while availability is unknown', () => {
    useBackendAvailability.mockReturnValue({ status: 'checking', retry })

    render(<ServiceCheck />)

    expect(screen.getByRole('status')).toHaveTextContent('Checking HåfaPass services')
  })

  it('shows the private preview and can retry when services are unavailable', async () => {
    const user = userEvent.setup()
    useBackendAvailability.mockReturnValue({ status: 'unavailable', retry })

    render(<ServiceCheck />)
    await user.click(screen.getByRole('button', { name: /check services again/i }))

    expect(retry).toHaveBeenCalledOnce()
  })

  it('renders the application through Clerk when services are available', () => {
    useBackendAvailability.mockReturnValue({ status: 'available', retry })

    render(<ServiceCheck />)

    expect(screen.getByTestId('clerk-provider')).toHaveTextContent('Public application')
  })
})
