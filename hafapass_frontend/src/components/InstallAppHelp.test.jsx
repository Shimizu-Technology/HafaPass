import { act, fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import InstallAppHelp from './InstallAppHelp'

afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals() })

it('offers browser instructions without implying every ticket works offline', async () => {
  render(<InstallAppHelp />)
  await userEvent.click(screen.getByText('Add HåfaPass to your phone'))
  expect(screen.getByText(/On iPhone or iPad/)).toBeVisible()
  expect(screen.getByText(/does not save every ticket/)).toBeVisible()
  expect(screen.queryByRole('button', { name: 'Install HåfaPass' })).not.toBeInTheDocument()
})

describe('browser installation offer', () => {
  it('opens installation only after the buyer asks and disappears once installed', async () => {
    render(<InstallAppHelp />)
    await userEvent.click(screen.getByText('Add HåfaPass to your phone'))
    const event = new Event('beforeinstallprompt', { cancelable: true })
    const prompt = vi.fn().mockResolvedValue(undefined)
    Object.assign(event, { prompt, userChoice: Promise.resolve({ outcome: 'accepted' }) })
    fireEvent(window, event)
    expect(event.defaultPrevented).toBe(true)
    expect(prompt).not.toHaveBeenCalled()
    await userEvent.click(screen.getByRole('button', { name: 'Install HåfaPass' }))
    expect(prompt).toHaveBeenCalledOnce()
    fireEvent(window, new Event('appinstalled'))
    expect(screen.queryByText('Add HåfaPass to your phone')).not.toBeInTheDocument()
  })

  it('keeps manual instructions available if the installation prompt fails', async () => {
    render(<InstallAppHelp />)
    await userEvent.click(screen.getByText('Add HåfaPass to your phone'))
    const event = new Event('beforeinstallprompt', { cancelable: true })
    Object.assign(event, { prompt: vi.fn().mockRejectedValue(new Error('Browser rejected')), userChoice: Promise.resolve({ outcome: 'dismissed' }) })
    fireEvent(window, event)
    await userEvent.click(screen.getByRole('button', { name: 'Install HåfaPass' }))
    expect(await screen.findByRole('status')).toHaveTextContent('Use your browser’s menu')
    expect(screen.queryByRole('button', { name: 'Install HåfaPass' })).not.toBeInTheDocument()
  })

  it('omits installation help in an installed window and responds to display changes', () => {
    let changed
    let standalone = true
    vi.stubGlobal('matchMedia', vi.fn(() => ({ matches: standalone,
      addEventListener: (_, listener) => { changed = listener }, removeEventListener: vi.fn() })))
    render(<InstallAppHelp />)
    expect(screen.queryByText('Add HåfaPass to your phone')).not.toBeInTheDocument()
    act(() => { standalone = false; changed() })
    expect(screen.getByText('Add HåfaPass to your phone')).toBeInTheDocument()
  })
})
