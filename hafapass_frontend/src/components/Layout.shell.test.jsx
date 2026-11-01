import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { HelmetProvider } from 'react-helmet-async'
import { Link, MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, expect, it, vi } from 'vitest'
import Layout from './Layout'

vi.mock('./Navbar', () => ({ default: () => <nav aria-label="Navbar stub" /> }))
vi.mock('./Footer', () => ({
  default: () => <footer>Marketing footer</footer>,
  WorkspaceFooter: () => <footer>Workspace footer</footer>,
}))
vi.mock('./EnvironmentBanner', () => ({ default: () => null }))
beforeEach(() => { window.scrollTo = vi.fn() })

const mount = (path, page = <h1>Page</h1>) => render(<HelmetProvider><MemoryRouter initialEntries={[path]}><Routes><Route element={<Layout />}>
  <Route path="*" element={page} />
</Route></Routes></MemoryRouter></HelmetProvider>)
const robots = () => document.head.querySelector('meta[name="robots"]')?.getAttribute('content') || null

it.each(['/dashboard', '/dashboard/events/6/edit', '/admin', '/admin/users', '/support'])('replaces the marketing footer on workspace route %s', path => {
  mount(path)
  expect(screen.getByText('Workspace footer')).toBeInTheDocument()
  expect(screen.queryByText('Marketing footer')).not.toBeInTheDocument()
})

it.each(['/events', '/my-tickets', '/dashboards-are-public'])('keeps the marketing footer on public route %s', path => {
  mount(path)
  expect(screen.getByText('Marketing footer')).toBeInTheDocument()
  expect(screen.queryByText('Workspace footer')).not.toBeInTheDocument()
})

it('leaves the home page to render its own footer', () => {
  mount('/')
  expect(screen.queryByRole('contentinfo')).not.toBeInTheDocument()
})

it('omits marketing navigation during checkout', () => {
  mount('/checkout/community-night')
  expect(screen.queryByRole('contentinfo')).not.toBeInTheDocument()
})

it.each([
  ['/dashboard', 'Dashboard'],
  ['/dashboard/events/6/box-office', 'Box office'],
  ['/dashboard/events/new', 'Create event'],
  ['/admin/organizations/4', 'Organization'],
  ['/admin/refund_reconciliation', 'Refund reconciliation'],
  ['/support', 'Support'],
  ['/tickets/private-credential', 'Your ticket'],
  ['/orders/12/confirmation', 'Your order'],
  ['/unsubscribe/token', 'Email preferences'],
  ['/ticket-transfers/accept', 'Ticket transfer'],
])('gives %s a route title that stays out of search indexes', async (path, title) => {
  mount(path)
  await waitFor(() => expect(document.title).toBe(`${title} | HåfaPass`))
  expect(robots()).toBe('noindex, nofollow, noarchive')
  expect(document.head.querySelector('link[rel="canonical"]')).not.toBeInTheDocument()
})

it('lets public pages own their title, canonical URL and indexing', () => {
  mount('/events')
  expect(robots()).toBeNull()
  expect(document.head.querySelector('link[rel="canonical"]')).not.toBeInTheDocument()
})

it('fades public pages in with CSS after a navigation, but not on first load', async () => {
  mount('/events', <><h1>Page</h1><Link to="/discover">Discover</Link></>)
  const firstPage = screen.getByRole('heading', { name: 'Page' }).parentElement
  expect(firstPage).not.toHaveClass('route-fade')
  fireEvent.click(screen.getByRole('link', { name: 'Discover' }))
  await waitFor(() => expect(screen.getByRole('heading', { name: 'Page' }).parentElement).toHaveClass('route-fade'))
  expect(screen.getByRole('heading', { name: 'Page' }).parentElement).not.toBe(firstPage)
})
