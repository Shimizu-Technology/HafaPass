import { useState } from 'react'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Link, Route, Routes } from 'react-router-dom'
import { beforeEach, expect, it, vi } from 'vitest'
import Layout from './Layout'
vi.mock('./Navbar', () => ({ default: () => <nav><Link to="/dashboard/new">Next page</Link></nav> }))
vi.mock('./Footer', () => ({ default: () => null }))
vi.mock('./EnvironmentBanner', () => ({ default: () => null }))
beforeEach(() => { window.scrollTo = vi.fn() })
function Page() {
  const [value, setValue] = useState('')
  return <><h1>New page</h1><input aria-label="Draft" value={value} onChange={event => setValue(event.target.value)} /><Link to="?filter=active">Filter</Link><Link to="#details">Details</Link><div id="details">Section</div></>
}
it('focuses and announces route headings while preserving focus on in-page updates and query/hash navigation', async () => {
  render(<MemoryRouter initialEntries={['/dashboard']}><Routes><Route element={<Layout />}><Route path="/dashboard" element={<h1>Dashboard</h1>} /><Route path="/dashboard/new" element={<Page />} /></Route></Routes></MemoryRouter>)
  fireEvent.click(screen.getByRole('link', { name: 'Next page' }))
  await waitFor(() => expect(screen.getByRole('heading', { name: 'New page' })).toHaveFocus())
  expect(screen.getByRole('status')).toHaveTextContent('New page')
  const input = screen.getByLabelText('Draft')
  input.focus()
  fireEvent.change(input, { target: { value: 'Unsaved' } })
  expect(input).toHaveFocus()
  fireEvent.click(screen.getByRole('link', { name: 'Filter' }))
  expect(input).toHaveFocus()
  fireEvent.click(screen.getByRole('link', { name: 'Details' }))
  expect(input).toHaveFocus()
  expect(window.scrollTo).toHaveBeenCalledTimes(1)
})
