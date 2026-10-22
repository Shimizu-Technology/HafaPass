import { render, screen, within, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import AdminLayout from './AdminLayout'
import AdminRoute from '../../components/AdminRoute'
import apiClient from '../../api/client'

vi.mock('@clerk/clerk-react', () => ({ useAuth: () => ({ isLoaded: true, isSignedIn: true, userId: 'test-user' }) }))
vi.mock('../../api/client', () => ({ default: { get: vi.fn() } }))
function RouteContent() { return <p>Working at {useLocation().pathname}</p> }
const shell = (path = '/admin/events') => render(<MemoryRouter initialEntries={[path]}><AdminLayout><RouteContent /></AdminLayout></MemoryRouter>)
beforeEach(() => { window.localStorage.clear(); vi.clearAllMocks() })

describe('admin workspace navigation', () => {
  it.each(['/admin', '/admin/events/42', '/admin/users', '/admin/orders', '/admin/marketplace', '/admin/payouts', '/admin/disputes', '/admin/settings', '/admin/provider-readiness', '/admin/audit-log', '/support'])('marks exactly the current destination at %s', path => {
    shell(path)
    const links = within(screen.getByRole('navigation', { name: 'Admin sidebar' })).getAllByRole('link')
    const current = links.filter(link => link.getAttribute('aria-current') === 'page')
    expect(current).toHaveLength(1)
    expect(path === '/admin' ? current[0].getAttribute('href') === path : path.startsWith(current[0].getAttribute('href'))).toBe(true)
  })
  it('groups destinations under Marketplace, Money and Platform headings', () => {
    shell('/admin/payouts')
    const nav = screen.getByRole('navigation', { name: 'Admin sidebar' })
    expect(within(nav).getAllByRole('list')).toHaveLength(4)
    expect(within(nav).getByText('Money').nextElementSibling).toHaveTextContent('PayoutsDisputes')
    expect(screen.getByRole('heading', { name: 'Payouts' })).toBeInTheDocument()
  })
  it('does not activate partial sibling route names', () => {
    shell('/admin/events-archive')
    expect(within(screen.getByRole('navigation', { name: 'Admin sidebar' })).getAllByRole('link').some(link => link.hasAttribute('aria-current'))).toBe(false)
  })
  it('persists the collapsed rail and retains accessible destination names', async () => {
    const view = shell()
    await userEvent.click(screen.getByRole('button', { name: 'Collapse admin sidebar' }))
    expect(window.localStorage.getItem('hafapass_admin_sidebar_collapsed')).toBe('true')
    const link = within(screen.getByRole('navigation', { name: 'Admin sidebar' })).getByRole('link', { name: 'Provider readiness' })
    expect(link).toHaveAttribute('href', '/admin/provider-readiness')
    expect(link.querySelector('span')).toHaveAttribute('aria-hidden', 'true')
    view.unmount(); shell()
    expect(screen.getByRole('button', { name: 'Expand admin sidebar' })).toHaveAttribute('aria-expanded', 'false')
  })
  it('traps drawer focus, makes the background inert and restores the trigger on Escape', async () => {
    const view = shell()
    const trigger = screen.getByRole('button', { name: 'Open admin navigation' })
    const user = userEvent.setup()
    await user.click(trigger)
    const dialog = screen.getByRole('dialog', { name: 'Admin navigation' })
    const close = within(dialog).getByRole('button', { name: 'Close admin navigation' })
    expect(dialog).toHaveAttribute('aria-modal', 'true')
    expect(view.container).toHaveAttribute('inert')
    expect(close).toHaveFocus()
    await user.tab({ shift: true })
    expect(within(dialog).getByRole('link', { name: 'Support' })).toHaveFocus()
    await user.tab(); expect(close).toHaveFocus()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(view.container).not.toHaveAttribute('inert')
    expect(view.container).not.toHaveAttribute('aria-hidden')
    expect(trigger).toHaveFocus()
    expect(trigger).toHaveAttribute('aria-expanded', 'false')
  })
  it('closes on navigation without losing the destination', async () => {
    shell()
    await userEvent.click(screen.getByRole('button', { name: 'Open admin navigation' }))
    await userEvent.click(within(screen.getByRole('dialog')).getByRole('link', { name: 'Users' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.getByText('Working at /admin/users')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Users' })).toBeInTheDocument()
  })
  it('closes on backdrop and restores existing background attributes', async () => {
    const borrowed = document.createElement('div')
    borrowed.setAttribute('inert', ''); borrowed.setAttribute('aria-hidden', 'false'); document.body.append(borrowed)
    try {
      shell()
      const trigger = screen.getByRole('button', { name: 'Open admin navigation' })
      await userEvent.click(trigger)
      fireEvent.mouseDown(screen.getByRole('dialog').parentElement)
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
      expect(borrowed).toHaveAttribute('inert')
      expect(borrowed).toHaveAttribute('aria-hidden', 'false')
      expect(trigger).toHaveFocus()
    } finally { borrowed.remove() }
  })
  it('keeps AdminRoute ahead of the workspace for a non-admin', async () => {
    apiClient.get.mockResolvedValue({ data: { role: 'support' } })
    render(<MemoryRouter initialEntries={['/admin/users']}><Routes>
      <Route path="/" element={<h1>Public events</h1>} />
      <Route path="/admin/users" element={<AdminRoute clerkConfigured><AdminLayout>Private users</AdminLayout></AdminRoute>} />
    </Routes></MemoryRouter>)
    expect(await screen.findByRole('heading', { name: 'Public events' })).toBeInTheDocument()
    expect(screen.queryByRole('navigation', { name: 'Admin sidebar' })).not.toBeInTheDocument()
    expect(screen.queryByText('Private users')).not.toBeInTheDocument()
  })
})
