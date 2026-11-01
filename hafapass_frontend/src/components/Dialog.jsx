import { useEffect, useRef } from 'react'

export default function Dialog({ children, labelledBy, onClose, busy = false, className = '', initialFocusRef }) {
  const ref = useRef(null)
  const closeRef = useRef(onClose)
  closeRef.current = onClose
  const busyRef = useRef(busy)
  busyRef.current = busy

  useEffect(() => {
    const previous = document.activeElement
    const scroll = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    // Skip controls with no layout box (display:none, hidden file inputs) so the
    // trap wraps at the last control a keyboard user can actually reach. jsdom
    // reports no boxes for anything, so fall back to every candidate there.
    const focusable = () => {
      const candidates = [...ref.current.querySelectorAll('button:not([disabled]), input:not([disabled]), textarea:not([disabled]), select:not([disabled]), a[href], [tabindex="0"]')]
      const rendered = candidates.filter(element => element.getClientRects().length > 0)
      return rendered.length ? rendered : candidates
    }
    ;(initialFocusRef?.current || focusable()[0] || ref.current).focus()
    const keydown = event => {
      if (event.key === 'Escape' && !busyRef.current) { event.preventDefault(); closeRef.current?.() }
      if (event.key !== 'Tab') return
      const elements = focusable()
      if (!elements.length) { event.preventDefault(); ref.current.focus(); return }
      if (!elements.includes(document.activeElement)) {
        event.preventDefault(); (event.shiftKey ? elements.at(-1) : elements[0]).focus(); return
      }
      const first = elements[0]
      const last = elements.at(-1)
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus() }
      if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus() }
    }
    const element = ref.current
    element.addEventListener('keydown', keydown)
    return () => {
      element.removeEventListener('keydown', keydown)
      document.body.style.overflow = scroll
      if (previous?.isConnected) previous.focus()
    }
  }, [initialFocusRef])

  return <div className="fixed inset-0 z-[70] flex items-center justify-center overflow-y-auto bg-black/50 px-4 py-6">
    <div ref={ref} tabIndex={-1} role="dialog" aria-modal="true" aria-labelledby={labelledBy} className={`max-h-[calc(100dvh-3rem)] w-full overflow-y-auto rounded-xl bg-white p-6 shadow-float ${className}`}>
      {children}
    </div>
  </div>
}
