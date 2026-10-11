import { StrictMode, useCallback, useState } from 'react'
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { createMemoryRouter, RouterProvider, MemoryRouter, Routes, Route, Link, useLocation } from 'react-router-dom'
import { beforeEach, describe, expect, it } from 'vitest'
import DraftNavigationProvider from './DraftNavigationProvider'
import useDraftProtection from '../hooks/useDraftProtection'

const authority = { scope: 'actor-a:org-a:session-a' }
let finishSave
function Editor({ scope }) {
  const [value, setValue] = useState('Saved event')
  const isCurrent = useCallback(() => authority.scope === scope, [scope])
  useDraftProtection({ dirty: value !== 'Saved event', scope, pathname: '/editor', isCurrent })
  return <div>
    <input aria-label="Event draft" value={value} onChange={event => setValue(event.target.value)} />
    <button onClick={() => setValue('Saved event')}>Save now</button>
    <button onClick={() => { finishSave = () => setValue('Saved event') }}>Save asynchronously</button>
    <Link to="/editor#ticket-types">Ticket types</Link>
    <Link to="/events">Workspace events</Link>
  </div>
}
function Shell() {
  const [scope, setScope] = useState(authority.scope)
  const location = useLocation()
  return <>
    <nav><Link to="/events">Navbar events</Link></nav>
    <output data-testid="location">{location.pathname}{location.search}{location.hash}</output>
    {['actor', 'organization', 'session'].map(kind => <button key={kind} onClick={() => {
      authority.scope = `replacement-${kind}`; setScope(authority.scope)
    }}>Replace {kind}</button>)}
    <Routes>
      <Route path="/editor" element={<Editor key={scope} scope={scope} />} />
      <Route path="/events" element={<h1>Events destination</h1>} />
    </Routes>
  </>
}
function mount(entries = ['/editor'], index = entries.length - 1) {
  const router = createMemoryRouter([{ path: '*', element: <DraftNavigationProvider><Shell /></DraftNavigationProvider> }], { initialEntries: entries, initialIndex: index })
  render(<StrictMode><RouterProvider router={router} /></StrictMode>)
  return router
}
beforeEach(() => { authority.scope = 'actor-a:org-a:session-a'; finishSave = undefined })
const dirty = async () => { await userEvent.clear(screen.getByLabelText('Event draft')); await userEvent.type(screen.getByLabelText('Event draft'), 'Unsaved event') }

describe('central event draft departure protection', () => {
  it('blocks shared navigation, preserves the draft on stay and approves one departure', async () => {
    mount(); await dirty()
    await userEvent.click(screen.getByRole('link', { name: 'Navbar events' }))
    expect(screen.getByTestId('location')).toHaveTextContent('/editor')
    expect(screen.getAllByRole('dialog')).toHaveLength(1)
    await userEvent.click(screen.getByRole('button', { name: 'Stay and save' }))
    expect(screen.getByLabelText('Event draft')).toHaveValue('Unsaved event')
    await userEvent.click(screen.getByRole('link', { name: 'Workspace events' }))
    await userEvent.click(screen.getByRole('button', { name: 'Leave without saving' }))
    expect(await screen.findByRole('heading', { name: 'Events destination' })).toBeInTheDocument()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })
  it('allows same-page hashes while keeping the mounted draft and blocks unload until saved', async () => {
    mount(); await dirty()
    const input = screen.getByLabelText('Event draft')
    await userEvent.click(screen.getByRole('link', { name: 'Ticket types' }))
    expect(screen.getByTestId('location')).toHaveTextContent('/editor#ticket-types')
    expect(screen.getByLabelText('Event draft')).toBe(input)
    expect(input).toHaveValue('Unsaved event')
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    const unload = new Event('beforeunload', { cancelable: true })
    window.dispatchEvent(unload); expect(unload.defaultPrevented).toBe(true)
    await userEvent.click(screen.getByRole('button', { name: 'Save now' }))
    const savedUnload = new Event('beforeunload', { cancelable: true })
    window.dispatchEvent(savedUnload); expect(savedUnload.defaultPrevented).toBe(false)
    await userEvent.click(screen.getByRole('link', { name: 'Navbar events' }))
    expect(await screen.findByRole('heading', { name: 'Events destination' })).toBeInTheDocument()
  })
  it('protects browser back and permits a later approved departure to the same history entry', async () => {
    const router = mount(['/events', '/editor']); await dirty()
    await act(async () => router.navigate(-1))
    expect(screen.getByTestId('location')).toHaveTextContent('/editor')
    await userEvent.click(screen.getByRole('button', { name: 'Stay and save' }))
    await act(async () => router.navigate(-1))
    await userEvent.click(screen.getByRole('button', { name: 'Leave without saving' }))
    await screen.findByRole('heading', { name: 'Events destination' })
    await act(async () => router.navigate(1))
    await dirty()
    await act(async () => router.navigate(-1))
    await userEvent.click(screen.getByRole('button', { name: 'Leave without saving' }))
    expect(await screen.findByRole('heading', { name: 'Events destination' })).toBeInTheDocument()
  })
  it('protects browser forward to another route', async () => {
    const router = mount(['/editor', '/events'], 0); await dirty()
    await act(async () => router.navigate(1))
    expect(screen.getByTestId('location')).toHaveTextContent('/editor')
    await userEvent.click(screen.getByRole('button', { name: 'Stay and save' }))
    expect(screen.getByLabelText('Event draft')).toHaveValue('Unsaved event')
  })
  it.each(['actor', 'organization', 'session'])('invalidates the old pending approval after %s replacement', async kind => {
    mount(); await dirty()
    await userEvent.click(screen.getByRole('link', { name: 'Navbar events' }))
    const oldLeave = screen.getByRole('button', { name: 'Leave without saving' })
    await userEvent.click(screen.getByRole('button', { name: `Replace ${kind}` }))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
    expect(screen.getByTestId('location')).toHaveTextContent('/editor')
    expect(screen.getByLabelText('Event draft')).toHaveValue('Saved event')
    fireEvent.click(oldLeave)
    expect(screen.getByTestId('location')).toHaveTextContent('/editor')
    await userEvent.click(screen.getByRole('link', { name: 'Navbar events' }))
    expect(await screen.findByRole('heading', { name: 'Events destination' })).toBeInTheDocument()
  })
  it('finishes the original requested navigation when its pending save makes the current draft clean', async () => {
    mount(); await dirty()
    await userEvent.click(screen.getByRole('button', { name: 'Save asynchronously' }))
    await userEvent.click(screen.getByRole('link', { name: 'Navbar events' }))
    expect(screen.getByRole('dialog')).toBeInTheDocument()
    await act(async () => finishSave())
    expect(await screen.findByRole('heading', { name: 'Events destination' })).toBeInTheDocument()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })
  it('does not require a data router for isolated BrowserRouter-style consumers', async () => {
    render(<MemoryRouter initialEntries={['/editor']}><DraftNavigationProvider><Editor scope={authority.scope} /></DraftNavigationProvider></MemoryRouter>)
    await dirty()
    const unload = new Event('beforeunload', { cancelable: true })
    window.dispatchEvent(unload)
    expect(unload.defaultPrevented).toBe(true)
    expect(screen.getByLabelText('Event draft')).toHaveValue('Unsaved event')
  })
})
