import { useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import { UNSAFE_DataRouterContext, useBlocker, useLocation } from 'react-router-dom'
import { DraftProtectionContext } from '../hooks/useDraftProtection'
import Dialog from './Dialog'

function DataRouterDraftProtection({ children }) {
  const location = useLocation()
  const registry = useRef(new Map())
  const [, setRegistryVersion] = useState(0)
  const pending = useRef(null)
  const sequence = useRef(0)
  const approved = useRef(null)
  const register = useCallback(entry => {
    registry.current.set(entry.id, entry)
    setRegistryVersion(value => value + 1)
    return () => {
      if (registry.current.get(entry.id) !== entry) return
      registry.current.delete(entry.id)
      setRegistryVersion(value => value + 1)
    }
  }, [])
  const manager = useMemo(() => ({ register }), [register])
  const activeDraft = useCallback(pathname => [...registry.current.values()].find(entry => entry.pathname === pathname && entry.dirty && entry.isCurrent()), [])
  const shouldBlock = useCallback(({ currentLocation, nextLocation }) => {
    // Hash changes do not abandon the mounted editor or its draft.
    if (currentLocation.pathname === nextLocation.pathname && currentLocation.search === nextLocation.search) return false
    const draft = activeDraft(currentLocation.pathname)
    if (!draft) return false
    pending.current = { id: draft.id, scope: draft.scope, attempt: ++sequence.current }
    return true
  }, [activeDraft])
  const blocker = useBlocker(shouldBlock)
  const blockerRef = useRef(blocker)
  blockerRef.current = blocker
  const entry = blocker.state === 'blocked' ? registry.current.get(pending.current?.id) || null : null
  const ownsPending = entry && entry.scope === pending.current?.scope && entry.pathname === location.pathname && entry.isCurrent()

  useEffect(() => {
    if (blocker.state !== 'blocked') return
    if (!ownsPending) blocker.reset()
    else if (!entry.dirty) blocker.proceed()
  }, [blocker, ownsPending, entry])
  useEffect(() => {
    const unload = event => {
      if (!activeDraft(location.pathname)) return
      event.preventDefault()
      event.returnValue = ''
    }
    window.addEventListener('beforeunload', unload)
    return () => window.removeEventListener('beforeunload', unload)
  }, [activeDraft, location.pathname])

  const stay = () => { if (blockerRef.current === blocker && blocker.state === 'blocked') blocker.reset() }
  const leave = () => {
    if (blockerRef.current !== blocker || blocker.state !== 'blocked' || !ownsPending || !entry.isCurrent()) return
    const attempt = pending.current?.attempt
    if (approved.current === attempt) return
    approved.current = attempt
    blocker.proceed()
  }
  return <DraftProtectionContext.Provider value={manager}>
    {children}
    {blocker.state === 'blocked' && ownsPending && entry.dirty && <Dialog labelledBy="central-draft-leave-title" onClose={stay}>
      <h2 id="central-draft-leave-title" className="text-lg font-semibold text-neutral-950">Leave unsaved event changes?</h2>
      <p className="mt-2 text-sm text-neutral-700">Your event has unsaved changes. Stay here to save them, or leave without saving.</p>
      <div className="mt-5 flex flex-wrap gap-3">
        <button type="button" className="btn-primary" onClick={stay}>Stay and save</button>
        <button type="button" className="btn-secondary" onClick={leave}>Leave without saving</button>
      </div>
    </Dialog>}
  </DraftProtectionContext.Provider>
}

export default function DraftNavigationProvider({ children }) {
  const dataRouter = useContext(UNSAFE_DataRouterContext)
  return dataRouter ? <DataRouterDraftProtection>{children}</DataRouterDraftProtection> : children
}
