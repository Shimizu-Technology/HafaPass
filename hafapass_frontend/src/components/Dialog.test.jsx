import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import Dialog from './Dialog'

describe('operational dialogs', () => {
  it('names the dialog, traps focus, closes with Escape, and restores the invoking control', async () => {
    const close = vi.fn()
    const previous = document.createElement('button')
    document.body.append(previous)
    previous.focus()
    const view = render(<Dialog labelledBy="confirm-title" onClose={close}><h2 id="confirm-title">Publish event?</h2><button>Cancel</button><button>Publish</button></Dialog>)
    const user = userEvent.setup()
    expect(screen.getByRole('dialog', { name: 'Publish event?' })).toHaveAttribute('aria-modal', 'true')
    expect(screen.getByRole('button', { name: 'Cancel' })).toHaveFocus()
    await user.tab({ shift: true })
    expect(screen.getByRole('button', { name: 'Publish' })).toHaveFocus()
    await user.tab()
    expect(screen.getByRole('button', { name: 'Cancel' })).toHaveFocus()
    await user.keyboard('{Escape}')
    expect(close).toHaveBeenCalledOnce()
    view.unmount()
    expect(previous).toHaveFocus()
    previous.remove()
  })
})
