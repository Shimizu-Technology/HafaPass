import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { useBackendAvailability } from './hooks/useBackendAvailability'
import { MemoryRouter, useNavigate } from 'react-router-dom'
import ServiceCheck from './ServiceCheck'
import { loadAuthorizedScanner } from './utils/admissionStore'
import { currentScannerOwner } from './utils/scannerAccountBinding'

vi.mock('./hooks/useBackendAvailability', () => ({
  useBackendAvailability: vi.fn(),
}))

vi.mock('./components/ClerkProviderWrapper', () => ({
  default: function MockClerkProvider({ children, loadingFallback }) {
    const { status } = useBackendAvailability()
    return <div data-testid="clerk-provider">{loadingFallback && status === 'available' && <div data-testid="auth-loading-fallback">{loadingFallback}</div>}{typeof children === 'function' ? children({ scannerOwner: currentScannerOwner() }) : children}</div>
  },
}))

vi.mock('./utils/admissionStore', () => ({ loadAuthorizedScanner: vi.fn() }))
vi.mock('./pages/dashboard/ScannerPage', () => ({ default: ({ offlineOnly, offlineEventId }) => <p data-event-id={offlineEventId}>{offlineOnly ? 'Cached door scanner' : 'Online scanner'}</p> }))

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
    loadAuthorizedScanner.mockReset()
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
    expect(screen.getByTestId('clerk-provider')).toBeInTheDocument()
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
    expect(screen.getByRole('link', { name: 'Reload to reconnect' })).toHaveAttribute('href', '/dashboard/scanner')
  })

  it('offers a full reload of the current scanner route so a failed auth script can restart', async () => {
    loadAuthorizedScanner.mockResolvedValue({ device: { id: 9 }, manifest: { payload: { event: { id: 38 } } } })
    useBackendAvailability.mockReturnValue({ status: 'unavailable', retry })
    render(<MemoryRouter initialEntries={['/dashboard/scanner?event=38#manual']}><ServiceCheck /></MemoryRouter>)
    expect(await screen.findByText('Cached door scanner')).toBeInTheDocument()
    const reconnect = screen.getByRole('link', { name: 'Reload to reconnect' })
    expect(reconnect).toHaveAttribute('href', '/dashboard/scanner?event=38#manual')
    expect(reconnect).not.toHaveAttribute('download')
    expect(screen.getByRole('status')).toHaveTextContent('Saved scans stay on this device')
    expect(retry).not.toHaveBeenCalled()
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

  it('boots only the explicitly requested saved event during an outage', async () => {
    window.localStorage.setItem('hafapass_scanner_event_id', '37')
    loadAuthorizedScanner.mockImplementation(id => Promise.resolve({ manifest: { payload: { event: { id: Number(id) } } } }))
    useBackendAvailability.mockReturnValue({ status: 'unavailable', retry })
    render(<MemoryRouter initialEntries={['/dashboard/scanner?event=38']}><ServiceCheck /></MemoryRouter>)
    expect(await screen.findByText('Cached door scanner')).toHaveAttribute('data-event-id', '38')
    expect(loadAuthorizedScanner).toHaveBeenCalledWith('38')
    expect(loadAuthorizedScanner).not.toHaveBeenCalledWith('37')
  })

  it.each(['38', ''])('does not substitute the last event when explicit event %s is unavailable', async requested => {
    window.localStorage.setItem('hafapass_scanner_event_id', '37')
    loadAuthorizedScanner.mockImplementation(id => Promise.resolve(id === '37' ? { manifest: { payload: { event: { id: 37 } } } } : null))
    useBackendAvailability.mockReturnValue({ status: 'unavailable', retry })
    render(<MemoryRouter initialEntries={[`/dashboard/scanner?event=${requested}`]}><ServiceCheck /></MemoryRouter>)
    await screen.findByRole('button', { name: /check services again/i })
    expect(screen.queryByText('Cached door scanner')).not.toBeInTheDocument()
    expect(loadAuthorizedScanner).not.toHaveBeenCalledWith('37')
  })

  it('rejects a cache result whose signed event does not match the URL target', async () => {
    useBackendAvailability.mockReturnValue({ status: 'unavailable', retry })
    loadAuthorizedScanner.mockResolvedValue({ manifest: { payload: { event: { id: 37 } } } })
    render(<MemoryRouter initialEntries={['/dashboard/scanner?event=38']}><ServiceCheck /></MemoryRouter>)
    await waitFor(() => expect(loadAuthorizedScanner).toHaveBeenCalledWith('38'))
    expect(screen.queryByText('Cached door scanner')).not.toBeInTheDocument()
  })

  it('ignores a verified cache result that finishes after its owner changes', async () => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'staff-a')
    useBackendAvailability.mockReturnValue({ status: 'unavailable', retry })
    let finishLoad
    loadAuthorizedScanner.mockReturnValue(new Promise(resolve => { finishLoad = resolve }))
    render(<MemoryRouter initialEntries={['/dashboard/scanner?event=37']}><ServiceCheck /></MemoryRouter>)
    await waitFor(() => expect(finishLoad).toBeDefined())
    window.localStorage.setItem('hafapass_scanner_user_id', 'staff-b')
    await act(async () => finishLoad({ manifest: { payload: { event: { id: 37 } } } }))
    expect(screen.queryByText('Cached door scanner')).not.toBeInTheDocument()
  })

  it('withdraws the old fallback immediately on query change and ignores a late old cache result', async () => {
    useBackendAvailability.mockReturnValue({ status: 'unavailable', retry })
    let resolveOld
    let resolveCurrent
    loadAuthorizedScanner.mockImplementation(id => new Promise(resolve => {
      if (id === '37') resolveOld = resolve
      else resolveCurrent = resolve
    }))
    function ChangeEvent() {
      const navigate = useNavigate()
      return <button onClick={() => navigate('/dashboard/scanner?event=38')}>Change event</button>
    }
    render(<MemoryRouter initialEntries={['/dashboard/scanner?event=37']}><ChangeEvent /><ServiceCheck /></MemoryRouter>)
    await waitFor(() => expect(resolveOld).toBeDefined())
    await userEvent.click(screen.getByRole('button', { name: 'Change event' }))
    await waitFor(() => expect(resolveCurrent).toBeDefined())
    await act(async () => resolveOld({ manifest: { payload: { event: { id: 37 } } } }))
    expect(screen.queryByText('Cached door scanner')).not.toBeInTheDocument()
    await act(async () => resolveCurrent({ manifest: { payload: { event: { id: 38 } } } }))
    expect(await screen.findByText('Cached door scanner')).toHaveAttribute('data-event-id', '38')
    // A subsequent navigation must also remove a fully resolved cache while the new target loads.
    await userEvent.click(screen.getByRole('button', { name: 'Change event' }))
    expect(screen.queryByText('Cached door scanner')).not.toBeInTheDocument()
  })
})
