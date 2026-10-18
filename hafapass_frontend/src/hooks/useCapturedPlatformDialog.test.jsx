import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { useState } from 'react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../api/client'
import useCapturedPlatformDialog from './useCapturedPlatformDialog'

const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done }); return { promise, resolve } }
let clearAuth, originalAdapter, pending
function Harness() {
  const [open, setOpen] = useState(false)
  const dialog = useCapturedPlatformDialog(open)
  return <><button onClick={() => { if (dialog.capture()) setOpen(true) }}>Open captured review</button>
    <button onClick={() => {
      const scope = dialog.begin('mutation')
      if (scope) pending = scope.api.post('/admin/synthetic/approve', { exact_snapshot: 7 }).then(value => ({ success: value }), error => ({ error })).finally(scope.finish)
    }}>Approve captured snapshot</button>
    <button onClick={() => setOpen(false)}>Withdraw dialog</button></>
}
beforeEach(() => { originalAdapter = apiClient.defaults.adapter; pending = null })
afterEach(() => { cleanup(); clearAuth?.(); clearAuth = null; apiClient.defaults.adapter = originalAdapter })

it('never reaches the Axios adapter when an old token resolves after account replacement', async () => {
  const token = deferred(), getterA = vi.fn(() => token.promise), getterB = vi.fn(() => Promise.resolve('synthetic-b'))
  clearAuth = setAuthTokenGetter(getterA, { userId: 'admin-a', sessionId: 'session-a', ready: true })
  const adapter = vi.fn(async config => ({ data: {}, status: 200, statusText: 'OK', headers: {}, config }))
  apiClient.defaults.adapter = adapter
  render(<Harness />)
  fireEvent.click(screen.getByRole('button', { name: 'Open captured review' }))
  fireEvent.click(screen.getByRole('button', { name: 'Approve captured snapshot' }))
  await waitFor(() => expect(getterA).toHaveBeenCalledOnce())
  await act(async () => { clearAuth = setAuthTokenGetter(getterB, { userId: 'admin-b', sessionId: 'session-b', ready: true }) })
  await act(async () => token.resolve('synthetic-a'))
  const result = await pending
  expect(result.error.name).toBe('CanceledError')
  expect(adapter).not.toHaveBeenCalled()
  expect(getterB).not.toHaveBeenCalled()
})

it('aborts queued transport when the dialog is withdrawn', async () => {
  const token = deferred(), getter = vi.fn(() => token.promise)
  clearAuth = setAuthTokenGetter(getter, { userId: 'admin-a', sessionId: 'session-a', ready: true })
  const adapter = vi.fn(async config => ({ data: {}, status: 200, statusText: 'OK', headers: {}, config }))
  apiClient.defaults.adapter = adapter
  render(<Harness />)
  fireEvent.click(screen.getByRole('button', { name: 'Open captured review' }))
  fireEvent.click(screen.getByRole('button', { name: 'Approve captured snapshot' }))
  await waitFor(() => expect(getter).toHaveBeenCalledOnce())
  fireEvent.click(screen.getByRole('button', { name: 'Withdraw dialog' }))
  await act(async () => token.resolve('synthetic-a'))
  expect((await pending).error.name).toBe('CanceledError')
  expect(adapter).not.toHaveBeenCalled()
})

it('never upgrades a queued no-auth development intent into a newly signed-in actor', async () => {
  setAuthTokenGetter(null)()
  const adapter = vi.fn(async config => ({ data: {}, status: 200, statusText: 'OK', headers: {}, config }))
  apiClient.defaults.adapter = adapter
  render(<Harness />)
  fireEvent.click(screen.getByRole('button', { name: 'Open captured review' }))
  await act(async () => {
    fireEvent.click(screen.getByRole('button', { name: 'Approve captured snapshot' }))
    clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-b'), { userId: 'admin-b', sessionId: 'session-b', ready: true })
  })
  expect((await pending).error.name).toBe('CanceledError')
  expect(adapter).not.toHaveBeenCalled()
})
