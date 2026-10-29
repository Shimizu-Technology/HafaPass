import { render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, expect, it, vi } from 'vitest'
import Layout from './Layout'

vi.mock('./Navbar', () => ({ default: () => <nav aria-label="Navbar stub" /> }))
vi.mock('./Footer', () => ({
  default: () => <footer>Marketing footer</footer>,
  WorkspaceFooter: () => <footer>Workspace footer</footer>,
}))
vi.mock('./EnvironmentBanner', () => ({ default: () => null }))
beforeEach(() => { window.scrollTo = vi.fn() })

const mount = path => render(<MemoryRouter initialEntries={[path]}><Routes><Route element={<Layout />}>
  <Route path="*" element={<h1>Page</h1>} />
</Route></Routes></MemoryRouter>)

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
