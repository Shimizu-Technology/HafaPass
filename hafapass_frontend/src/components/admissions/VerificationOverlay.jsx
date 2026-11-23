import { useEffect, useId, useRef } from 'react'
import DoorScanCard from './DoorScanCard'

export default function VerificationOverlay({ ticket, onConfirm, onCancel, busy }) {
  const dialogRef = useRef(null)
  const cancelRef = useRef(onCancel)
  cancelRef.current = onCancel
  const titleId = useId()

  useEffect(() => {
    const dialog = dialogRef.current
    const [confirm, cancel] = dialog.querySelectorAll('button')
    const previous = document.activeElement
    // Focus the heading container first, so a repeated Enter cannot admit.
    dialog.focus({ preventScroll: true })
    const onKeyDown = event => {
      if (event.key === 'Escape') {
        event.preventDefault()
        cancelRef.current()
      } else if (event.key === 'Tab') {
        event.preventDefault()
        const next = event.shiftKey
          ? (document.activeElement === cancel ? confirm : cancel)
          : (document.activeElement === confirm ? cancel : confirm)
        next.focus()
      }
    }
    const onFocusIn = event => {
      if (!dialog.contains(event.target)) dialog.focus({ preventScroll: true })
    }
    document.addEventListener('keydown', onKeyDown)
    document.addEventListener('focusin', onFocusIn)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
      document.removeEventListener('focusin', onFocusIn)
      if (previous instanceof HTMLElement && previous.isConnected && (dialog.contains(document.activeElement) || document.activeElement === document.body)) {
        previous.focus({ preventScroll: true })
      }
    }
  }, [])

  return (
    <div ref={dialogRef} tabIndex={-1} role="dialog" aria-modal="true" aria-labelledby={titleId}
      className="fixed inset-0 z-[60] overflow-y-auto overscroll-contain bg-neutral-950 focus:outline-none">
      <div className="flex min-h-full items-center justify-center">
        <DoorScanCard ticket={ticket} verifying titleId={titleId} onConfirm={onConfirm} onCancel={onCancel} busy={busy} />
      </div>
    </div>
  )
}
