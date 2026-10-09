import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { useBackendAvailability } from './hooks/useBackendAvailability'
import { MemoryRouter } from 'react-router-dom'
import ServiceCheck from './ServiceCheck'
import { loadAuthorizedScanner } from './utils/admissionStore'

vi.mock('./hooks/useBackendAvailability', () => ({
  useBackendAvailability: vi.fn(),
}))

vi.mock('./components/ClerkProviderWrapper', () => ({
  default: ({ children, loadingFallback }) => <div data-testid="clerk-provider">{loadingFallback && <div data-testid="auth-loading-fallback">{loadingFallback}</div>}{children}</div>,
}))

vi.mock('./utils/admissionStore', () => ({ loadAuthorizedScanner: vi.fn() }))
vi.mock('./pages/dashboard/ScannerPage', () => ({ default: ({ offlineOnly }) => <p>{offlineOnly ? 'Cached door scanner' : 'Online scanner'}</p> }))

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
    window.localStorage.clear()
    loadAuthorizedScanner.mockResolvedValue(null)
  })

  it('shows a service check while availability is unknown', () => {
    useBackendAvailability.mockReturnValue({ status: 'checking', retry })

    render(<MemoryRouter><ServiceCheck /></MemoryRouter>)

    expect(screen.getByRole('status')).toHaveTextContent('Checking HåfaPass services')
  })

  it('shows the private preview and can retry when services are unavailable', async () => {
    const user = userEvent.setup()
    useBackendAvailability.mockReturnValue({ status: 'unavailable', retry })

    render(<MemoryRouter><ServiceCheck /></MemoryRouter>)
    await user.click(screen.getByRole('button', { name: /check services again/i }))

    expect(retry).toHaveBeenCalledOnce()
  })

  it('allows a previously authorized scanner to boot through the health outage', async () => {
    window.localStorage.setItem('hafapass_scanner_event_id', '37')
    loadAuthorizedScanner.mockResolvedValue({ device: { id: 9 }, manifest: { payload: { event: { id: 37 } } } })
    useBackendAvailability.mockReturnValue({ status: 'unavailable', retry })
    render(<MemoryRouter initialEntries={['/dashboard/scanner']}><ServiceCheck /></MemoryRouter>)
    expect(await screen.findByText('Cached door scanner')).toBeInTheDocument()
    expect(screen.queryByTestId('clerk-provider')).not.toBeInTheDocument()
    expect(loadAuthorizedScanner).toHaveBeenCalledWith('37')
  })

  it('renders the application through Clerk when services are available', () => {
    useBackendAvailability.mockReturnValue({ status: 'available', retry })

    render(<MemoryRouter><ServiceCheck /></MemoryRouter>)

    expect(screen.getByTestId('clerk-provider')).toHaveTextContent('Public application')
  })

  it('supplies the verified scanner cache during Clerk loading even when backend health is available', async () => {
    window.localStorage.setItem('hafapass_scanner_event_id', '37')
    loadAuthorizedScanner.mockResolvedValue({ device: { id: 9 }, manifest: { payload: { event: { id: 37 } } } })
    useBackendAvailability.mockReturnValue({ status: 'available', retry })
    render(<MemoryRouter initialEntries={['/dashboard/scanner']}><ServiceCheck /></MemoryRouter>)
    expect(await screen.findByTestId('auth-loading-fallback')).toHaveTextContent('Cached door scanner')
  })

  it('reloads saved authorization when health changes after an online scanner was prepared', async () => {
    window.localStorage.setItem('hafapass_scanner_event_id', '37')
    useBackendAvailability.mockReturnValue({ status: 'available', retry })
    const { rerender } = render(<MemoryRouter initialEntries={['/dashboard/scanner']}><ServiceCheck /></MemoryRouter>)
    await screen.findByText('Public application')
    loadAuthorizedScanner.mockResolvedValue({ device: { id: 9 }, manifest: { payload: { event: { id: 37 } } } })
    useBackendAvailability.mockReturnValue({ status: 'unavailable', retry })
    rerender(<MemoryRouter initialEntries={['/dashboard/scanner']}><ServiceCheck /></MemoryRouter>)
    expect(await screen.findByText('Cached door scanner')).toBeInTheDocument()
  })
})
