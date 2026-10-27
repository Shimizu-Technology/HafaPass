import { useCallback, useState } from 'react'
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { createMemoryRouter, RouterProvider, useLocation } from 'react-router-dom'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { registerSW } from 'virtual:pwa-register'
import DraftNavigationProvider from './DraftNavigationProvider'
import ReleaseUpdateCoordinator from './ReleaseUpdateCoordinator'
import useDraftProtection from '../hooks/useDraftProtection'

vi.mock('virtual:pwa-register', () => ({ registerSW: vi.fn() }))
const A = 'a'.repeat(40)
const B = 'b'.repeat(40)
let shellRevision
let originalLocation
const reload = vi.fn()
function Draft() {
  const location = useLocation()
  const [dirty, setDirty] = useState(false)
  const isCurrent = useCallback(() => true, [])
  useDraftProtection({ dirty, pathname: location.pathname, scope: 'synthetic', isCurrent })
  return <button onClick={() => setDirty(true)}>Make registered draft dirty</button>
}
function mount(path = '/') {
  const router = createMemoryRouter([{ path: '*', element: <DraftNavigationProvider><ReleaseUpdateCoordinator /><Draft /></DraftNavigationProvider> }], { initialEntries: [path] })
  render(<RouterProvider router={router} />)
  return router
}
beforeEach(() => {
  vi.stubEnv('PROD', true)
  vi.stubEnv('VITE_SENTRY_RELEASE', A)
  shellRevision = A
  sessionStorage.clear()
  reload.mockReset()
  registerSW.mockClear()
  originalLocation = window.location
  Object.defineProperty(window, 'location', { configurable: true, value: { ...originalLocation, reload } })
  vi.stubGlobal('fetch', vi.fn(async url => ({ ok: true, json: async () => ({ revision: B }), text: async () => url === '/index.html' ? `<meta name="hafapass-revision" content="${shellRevision}">` : '' })))
})
afterEach(() => {
  Object.defineProperty(window, 'location', { configurable: true, value: originalLocation })
  vi.unstubAllGlobals()
  vi.unstubAllEnvs()
})
it('waits for the new worker shell even when release.json already advertises B', async () => {
  mount()
  await waitFor(() => expect(fetch).toHaveBeenCalledWith('/index.html', expect.anything()))
  expect(reload).not.toHaveBeenCalled()
  shellRevision = B
  await act(async () => registerSW.mock.calls[0][0].onNeedReload())
  expect(reload).toHaveBeenCalledTimes(1)
})
it('keeps checkout mounted after activation and reloads once on safe navigation', async () => {
  const router = mount('/checkout/show')
  shellRevision = B
  await act(async () => registerSW.mock.calls[0][0].onNeedReload())
  expect(reload).not.toHaveBeenCalled()
  await act(async () => router.navigate('/events'))
  expect(reload).toHaveBeenCalledTimes(1)
})
it('queries the existing draft registry even on a public route', async () => {
  mount()
  fireEvent.click(screen.getByRole('button', { name: 'Make registered draft dirty' }))
  shellRevision = B
  await act(async () => registerSW.mock.calls[0][0].onNeedReload())
  expect(reload).not.toHaveBeenCalled()
  expect(window.hafapassCanRecoverShell()).toBe(false)
})

it('does not treat a same-page anchor as the next route navigation', async () => {
  const router = mount('/events/show')
  shellRevision = B
  await act(async () => registerSW.mock.calls[0][0].onNeedReload())
  await act(async () => router.navigate('/events/show#tickets'))
  expect(reload).not.toHaveBeenCalled()
  await act(async () => router.navigate('/events'))
  expect(reload).toHaveBeenCalledTimes(1)
})
