import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useBackendAvailability } from './hooks/useBackendAvailability'
import { MemoryRouter, useNavigate } from 'react-router-dom'
import ServiceCheck, { GATE_DELAY_MS, HEALTH_CACHE_KEY, HEALTH_CACHE_TTL_MS } from './ServiceCheck'
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
  default: () => <div>Public application<input aria-label="Draft note" /></div>,
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
    window.sessionStorage.clear()
    loadAuthorizedScanner.mockResolvedValue(null)
  })

  describe('loading gate', () => {
    afterEach(() => vi.useRealTimers())

    it('never shows the gate when the check finishes quickly', () => {
      vi.useFakeTimers()
      useBackendAvailability.mockReturnValue({ status: 'checking', retry })
      const { rerender } = render(<MemoryRouter><ServiceCheck /></MemoryRouter>)
      act(() => { vi.advanceTimersByTime(GATE_DELAY_MS - 50) })
      expect(screen.queryByText(/Checking HåfaPass services/)).not.toBeInTheDocument()
      useBackendAvailability.mockReturnValue({ status: 'available', retry })
      rerender(<MemoryRouter><ServiceCheck /></MemoryRouter>)
      act(() => { vi.advanceTimersByTime(GATE_DELAY_MS) })
      expect(screen.queryByText(/Checking HåfaPass services/)).not.toBeInTheDocument()
      expect(screen.getByText('Public application')).toBeInTheDocument()
    })

    it('shows a light, motion-safe gate when the check is slow', () => {
      vi.useFakeTimers()
      useBackendAvailability.mockReturnValue({ status: 'checking', retry })
      render(<MemoryRouter><ServiceCheck /></MemoryRouter>)
      act(() => { vi.advanceTimersByTime(GATE_DELAY_MS) })
      const gate = screen.getByRole('status')
      expect(gate).toHaveTextContent('Checking HåfaPass services')
      expect(gate).toHaveClass('bg-neutral-50')
      expect(gate).not.toHaveClass('bg-neutral-950')
      // Reduced motion: the spinner only rotates under prefers-reduced-motion: no-preference.
      const spinner = gate.querySelector('[aria-hidden="true"]')
      expect(spinner).toHaveClass('motion-safe:animate-spin')
      expect(spinner).not.toHaveClass('animate-spin')
    })

    it('renders immediately after a recent successful check in this session', () => {
      window.sessionStorage.setItem(HEALTH_CACHE_KEY, String(Date.now()))
      useBackendAvailability.mockReturnValue({ status: 'checking', retry })
      render(<MemoryRouter><ServiceCheck /></MemoryRouter>)
      expect(screen.getByText('Public application')).toBeInTheDocument()
    })

    it('ignores an expired success and remembers a new one', () => {
      vi.useFakeTimers()
      window.sessionStorage.setItem(HEALTH_CACHE_KEY, String(Date.now() - HEALTH_CACHE_TTL_MS - 1))
      useBackendAvailability.mockReturnValue({ status: 'checking', retry })
      const { rerender } = render(<MemoryRouter><ServiceCheck /></MemoryRouter>)
      act(() => { vi.advanceTimersByTime(GATE_DELAY_MS) })
      expect(screen.getByRole('status')).toHaveTextContent('Checking HåfaPass services')
      useBackendAvailability.mockReturnValue({ status: 'available', retry })
      rerender(<MemoryRouter><ServiceCheck /></MemoryRouter>)
      expect(Number(window.sessionStorage.getItem(HEALTH_CACHE_KEY))).toBeGreaterThan(Date.now() - 1000)
    })

    it('keeps the rendered application and its typed state when the background check fails', async () => {
      const user = userEvent.setup()
      window.sessionStorage.setItem(HEALTH_CACHE_KEY, String(Date.now()))
      useBackendAvailability.mockReturnValue({ status: 'checking', retry })
      const { rerender } = render(<MemoryRouter><ServiceCheck /></MemoryRouter>)
      await user.type(screen.getByRole('textbox', { name: 'Draft note' }), 'Table for six')
      useBackendAvailability.mockReturnValue({ status: 'unavailable', retry })
      rerender(<MemoryRouter><ServiceCheck /></MemoryRouter>)
      expect(screen.getByRole('textbox', { name: 'Draft note' })).toHaveValue('Table for six')
      expect(screen.getByRole('alert')).toHaveTextContent('We’re having trouble reaching HåfaPass')
      expect(screen.queryByRole('button', { name: /check services again/i })).not.toBeInTheDocument()
      expect(window.sessionStorage.getItem(HEALTH_CACHE_KEY)).toBeNull()
      await user.click(screen.getByRole('button', { name: 'Try again' }))
      expect(retry).toHaveBeenCalledOnce()
      // Recovery clears the banner without remounting the application.
      useBackendAvailability.mockReturnValue({ status: 'available', retry })
      rerender(<MemoryRouter><ServiceCheck /></MemoryRouter>)
      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
      expect(screen.getByRole('textbox', { name: 'Draft note' })).toHaveValue('Table for six')
    })

    it('keeps the full outage page when nothing has rendered yet', () => {
      useBackendAvailability.mockReturnValue({ status: 'unavailable', retry })
      render(<MemoryRouter><ServiceCheck /></MemoryRouter>)
      expect(screen.getByRole('button', { name: /check services again/i })).toBeInTheDocument()
      expect(screen.queryByText('Public application')).not.toBeInTheDocument()
    })

    it('ignores the session shortcut on the door scanner so saved access opens first', async () => {
      window.sessionStorage.setItem(HEALTH_CACHE_KEY, String(Date.now()))
      window.localStorage.setItem('hafapass_scanner_event_id', '37')
      loadAuthorizedScanner.mockResolvedValue({ device: { id: 9 }, manifest: { payload: { event: { id: 37 } } } })
      useBackendAvailability.mockReturnValue({ status: 'checking', retry })
      render(<MemoryRouter initialEntries={['/dashboard/scanner']}><ServiceCheck /></MemoryRouter>)
      expect(screen.queryByText('Public application')).not.toBeInTheDocument()
      expect(await screen.findByText('Cached door scanner')).toBeInTheDocument()
      expect(screen.queryByText('Public application')).not.toBeInTheDocument()
    })

    it('does not trust a success timestamp from the future', () => {
      vi.useFakeTimers()
      window.sessionStorage.setItem(HEALTH_CACHE_KEY, String(Date.now() + 60_000))
      useBackendAvailability.mockReturnValue({ status: 'checking', retry })
      render(<MemoryRouter><ServiceCheck /></MemoryRouter>)
      expect(screen.queryByText('Public application')).not.toBeInTheDocument()
      act(() => { vi.advanceTimersByTime(GATE_DELAY_MS) })
      expect(screen.getByRole('status')).toHaveTextContent('Checking HåfaPass services')
    })

    it('still gates and renders when session storage throws', () => {
      vi.useFakeTimers()
      const fail = () => { throw new Error('SecurityError') }
      const getItem = vi.spyOn(Storage.prototype, 'getItem').mockImplementation(fail)
      const setItem = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(fail)
      const removeItem = vi.spyOn(Storage.prototype, 'removeItem').mockImplementation(fail)
      try {
        useBackendAvailability.mockReturnValue({ status: 'checking', retry })
        const { rerender } = render(<MemoryRouter><ServiceCheck /></MemoryRouter>)
        act(() => { vi.advanceTimersByTime(GATE_DELAY_MS) })
        expect(screen.getByRole('status')).toHaveTextContent('Checking HåfaPass services')
        useBackendAvailability.mockReturnValue({ status: 'available', retry })
        rerender(<MemoryRouter><ServiceCheck /></MemoryRouter>)
        expect(screen.getByText('Public application')).toBeInTheDocument()
        expect(setItem).toHaveBeenCalled()
      } finally {
        getItem.mockRestore(); setItem.mockRestore(); removeItem.mockRestore()
      }
    })
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
    expect(screen.getByRole('button', { name: 'Reload to reconnect' })).toHaveAttribute('type', 'button')
  })

  it('offers an explicit reconnect action on a scanner route with a fragment', async () => {
    loadAuthorizedScanner.mockResolvedValue({ device: { id: 9 }, manifest: { payload: { event: { id: 38 } } } })
    useBackendAvailability.mockReturnValue({ status: 'unavailable', retry })
    render(<MemoryRouter initialEntries={['/dashboard/scanner?event=38#manual']}><ServiceCheck /></MemoryRouter>)
    expect(await screen.findByText('Cached door scanner')).toBeInTheDocument()
    const reconnect = screen.getByRole('button', { name: 'Reload to reconnect' })
    expect(reconnect).toHaveAttribute('type', 'button')
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

  it('does not keep the online app on the door scanner while saved access is still loading during an outage', async () => {
    useBackendAvailability.mockReturnValue({ status: 'available', retry })
    let resolveSaved
    loadAuthorizedScanner.mockImplementation(() => new Promise(resolve => { resolveSaved = resolve }))
    function OpenScanner() {
      const navigate = useNavigate()
      return <button onClick={() => navigate('/dashboard/scanner?event=37')}>Open scanner</button>
    }
    const tree = <MemoryRouter initialEntries={['/dashboard']}><OpenScanner /><ServiceCheck /></MemoryRouter>
    const { rerender } = render(tree)
    expect(screen.getByText('Public application')).toBeInTheDocument()
    useBackendAvailability.mockReturnValue({ status: 'unavailable', retry })
    rerender(tree)
    await userEvent.click(screen.getByRole('button', { name: 'Open scanner' }))
    await waitFor(() => expect(resolveSaved).toBeDefined())
    expect(screen.queryByText('Public application')).not.toBeInTheDocument()
    await act(async () => resolveSaved({ manifest: { payload: { event: { id: 37 } } } }))
    expect(await screen.findByText('Cached door scanner')).toBeInTheDocument()
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
