import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { expect, it } from 'vitest'
import PageLoading from './PageLoading'
import RouteLoading from './RouteLoading'
import css from '../index.css?raw'

it('names a silent route status and paints dark-page routes dark', () => {
  render(<MemoryRouter initialEntries={['/host']}><RouteLoading /></MemoryRouter>)
  const status = screen.getByRole('status', { name: 'Loading page' })
  expect(status).toHaveClass('route-loading', 'bg-brand-950')
  expect(status).toHaveTextContent('HåfaPass')
})

it('keeps light routes on the light page', () => {
  render(<MemoryRouter initialEntries={['/events/community-night']}><RouteLoading /></MemoryRouter>)
  expect(screen.getByRole('status', { name: 'Loading page' })).not.toHaveClass('bg-brand-950')
})

it('shows a message under the wordmark with a static header in place of the navigation', () => {
  render(<MemoryRouter initialEntries={['/my-tickets']}><PageLoading header message="Preparing your account…" /></MemoryRouter>)
  const status = screen.getByRole('status')
  expect(status).toHaveTextContent('Preparing your account…')
  expect(status.querySelector('.page-loading-mark')).toHaveAttribute('aria-hidden', 'true')
  expect(screen.getByRole('banner')).toHaveClass('bg-brand-950')
  expect(screen.getByRole('link', { name: 'HåfaPass' })).toHaveAttribute('href', '/')
})

it('renders outside a router for the account wrapper', () => {
  render(<PageLoading label="Checking administrator access" />)
  expect(screen.getByRole('status', { name: 'Checking administrator access' })).toBeInTheDocument()
})

it('pulses spinners instead of freezing them under reduced motion', () => {
  const reduced = css.slice(css.lastIndexOf('@media (prefers-reduced-motion: reduce)'))
  expect(reduced).toMatch(/\[class\*="animate-spin"\][^{]*\{\s*animation: loading-pulse[^}]*!important/)
})
