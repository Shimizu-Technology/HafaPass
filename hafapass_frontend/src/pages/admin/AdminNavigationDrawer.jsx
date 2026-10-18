import { useEffect, useId, useRef } from 'react'
import { createPortal } from 'react-dom'
import { X } from 'lucide-react'
import Dialog from '../../components/Dialog'

export default function AdminNavigationDrawer({ id, children, onClose }) {
  const titleId = useId()
  const layerRef = useRef(null)

  useEffect(() => {
    // Dialog supplies focus trapping/return and scroll locking. Inert every
    // background root, including the shared public header, while this portal is open.
    const background = [...document.body.children].filter(element => element !== layerRef.current)
    const previous = background.map(element => ({ element, inert: element.getAttribute('inert'), hidden: element.getAttribute('aria-hidden') }))
    background.forEach(element => { element.setAttribute('inert', ''); element.setAttribute('aria-hidden', 'true') })
    return () => previous.forEach(({ element, inert, hidden }) => {
      if (inert === null) element.removeAttribute('inert'); else element.setAttribute('inert', inert)
      if (hidden === null) element.removeAttribute('aria-hidden'); else element.setAttribute('aria-hidden', hidden)
    })
  }, [])

  return createPortal(
    <div id={id} ref={layerRef} onMouseDown={event => { if (!event.target.closest('[role="dialog"]')) onClose() }}>
      <Dialog labelledBy={titleId} onClose={onClose} className="absolute inset-y-0 left-0 !h-dvh !max-h-none !w-[min(88vw,20rem)] !rounded-none !p-4">
        <div className="mb-5 flex items-center justify-between gap-3 border-b border-neutral-200 pb-4">
          <h2 id={titleId} className="font-semibold text-neutral-900">Admin navigation</h2>
          <button type="button" onClick={onClose} aria-label="Close admin navigation" className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg text-content-muted hover:bg-neutral-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2">
            <X aria-hidden="true" className="h-5 w-5" />
          </button>
        </div>
        {children}
      </Dialog>
    </div>, document.body,
  )
}
