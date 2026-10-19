import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { expect, it } from 'vitest'
import { BackLink, PageHeader, WorkspacePage } from './WorkspacePage'

it('renders the standard back link to the dashboard with a decorative chevron', () => {
  render(<MemoryRouter><BackLink /></MemoryRouter>)
  const link = screen.getByRole('link', { name: 'Back to dashboard' })
  expect(link).toHaveAttribute('href', '/dashboard')
  expect(link.querySelector('svg')).toHaveAttribute('aria-hidden', 'true')
})

it('accepts a custom destination and label', () => {
  render(<MemoryRouter><BackLink to="/dashboard/events/6/edit">Back to event</BackLink></MemoryRouter>)
  expect(screen.getByRole('link', { name: 'Back to event' })).toHaveAttribute('href', '/dashboard/events/6/edit')
})

it('lays out a page header with one heading, description and actions inside the shared width', () => {
  const { container } = render(<MemoryRouter><WorkspacePage width="form">
    <PageHeader back={<BackLink />} eyebrow="Organization" title="Island Nights" titleId="org-title" description="Team access" actions={<button>Save</button>} />
  </WorkspacePage></MemoryRouter>)
  expect(container.firstChild).toHaveClass('max-w-3xl')
  expect(screen.getByRole('heading', { level: 1, name: 'Island Nights' })).toHaveAttribute('id', 'org-title')
  expect(screen.getByText('Team access')).toBeInTheDocument()
  expect(screen.getByRole('button', { name: 'Save' })).toBeInTheDocument()
})

it('defaults to the standard workspace width', () => {
  const { container } = render(<WorkspacePage>Body</WorkspacePage>)
  expect(container.firstChild).toHaveClass('max-w-6xl')
})
