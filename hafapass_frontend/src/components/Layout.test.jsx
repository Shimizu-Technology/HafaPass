import { useEffect, useState } from 'react'
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
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

it.each([false, true])('orients a loaded heading without taking focus back after user movement=%s', async moved => {
  let finish
  const loaded = new Promise(resolve => { finish = resolve })
  function AsyncPage() {
    const [ready, setReady] = useState(false)
    useEffect(() => {
      let active = true
      loaded.then(() => { if (active) setReady(true) })
      return () => { active = false }
    }, [])
    return <>{ready ? <h1>Loaded event</h1> : <p>Preparing event</p>}<input aria-label="Keep typing" /></>
  }
  render(<MemoryRouter initialEntries={['/dashboard']}><Routes><Route element={<Layout />}><Route path="/dashboard" element={<h1>Dashboard</h1>} /><Route path="/dashboard/new" element={<AsyncPage />} /></Route></Routes></MemoryRouter>)
  fireEvent.click(screen.getByRole('link', { name: 'Next page' }))
  expect(screen.getByRole('main')).toHaveFocus()
  const input = screen.getByLabelText('Keep typing')
  if (moved) input.focus()
  await act(async () => finish())
  await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('Loaded event'))
  expect(moved ? input : screen.getByRole('heading', { name: 'Loaded event' })).toHaveFocus()
})
