import { createContext, useContext, useId, useLayoutEffect, useEffect, useRef } from 'react'

export const DraftProtectionContext = createContext(null)

// Scope and current authority come from the page's existing identity/session
// boundary. A navigation approval never grants access or transfers a draft.
export default function useDraftProtection({ dirty, scope, pathname, isCurrent }) {
  const manager = useContext(DraftProtectionContext)
  const id = useId()
  const latest = useRef(null)
  latest.current = { dirty, scope, pathname, isCurrent }
  useLayoutEffect(() => {
    if (!manager) return undefined
    return manager.register({ id, dirty, scope, pathname, isCurrent })
  }, [manager, id, dirty, scope, pathname, isCurrent])
  useEffect(() => {
    if (manager) return undefined
    // Isolated BrowserRouter/MemoryRouter consumers keep their local link
    // guard and still protect full-document departure without calling useBlocker.
    const unload = event => {
      const draft = latest.current
      if (!draft.dirty || !draft.isCurrent()) return
      event.preventDefault()
      event.returnValue = ''
    }
    window.addEventListener('beforeunload', unload)
    return () => window.removeEventListener('beforeunload', unload)
  }, [manager])
  return Boolean(manager)
}
