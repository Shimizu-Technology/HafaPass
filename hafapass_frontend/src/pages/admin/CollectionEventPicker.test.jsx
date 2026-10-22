import { useState } from 'react'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import CollectionEventPicker from './CollectionEventPicker'

const events = [
  { id: 6, title: 'Full Moon Beach Party', organizer_name: 'Island Nights Promotions', status: 'published' },
  { id: 9, title: 'Sunset Jazz', organizer_name: 'Island Nights Promotions', status: 'draft' },
  { id: 12, title: 'Chamorro Food Fest', organizer_name: 'Guam Eats', status: 'published' },
]
// An event beyond the first loaded page: only the server search can find it.
const laterEvent = { id: 140, title: 'Liberation Day Carnival', organizer_name: 'Guam Visitors Bureau', status: 'published' }

const serverSearch = () => vi.fn((term, signal) => Promise.resolve(
  [...events, laterEvent].filter(event => event.title.toLowerCase().includes(term.toLowerCase())),
).then(results => { if (signal.aborted) throw new Error('aborted'); return results }))

function Harness({ onChange, searchEvents = serverSearch() }) {
  const [value, setValue] = useState([])
  return <CollectionEventPicker events={events} searchEvents={searchEvents} value={value} onChange={next => { setValue(next); onChange(next) }} />
}
const searchbox = () => screen.getByRole('searchbox', { name: 'Search events to add' })

describe('CollectionEventPicker', () => {
  it('shows an empty state until events are added', () => {
    render(<Harness onChange={vi.fn()} />)
    expect(screen.getByText(/No events added yet/)).toBeInTheDocument()
  })

  it('builds, reorders and trims the ordered event id list', async () => {
    const onChange = vi.fn()
    render(<Harness onChange={onChange} />)
    await userEvent.click(screen.getByRole('button', { name: 'Add Chamorro Food Fest' }))
    await userEvent.click(screen.getByRole('button', { name: 'Add Full Moon Beach Party' }))
    await userEvent.click(screen.getByRole('button', { name: 'Add Sunset Jazz' }))
    expect(onChange).toHaveBeenLastCalledWith([12, 6, 9])

    await userEvent.click(screen.getByRole('button', { name: 'Move Sunset Jazz up' }))
    expect(onChange).toHaveBeenLastCalledWith([12, 9, 6])
    await userEvent.click(screen.getByRole('button', { name: 'Remove Chamorro Food Fest' }))
    expect(onChange).toHaveBeenLastCalledWith([9, 6])
    expect(screen.getByRole('button', { name: 'Move Sunset Jazz up' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Move Full Moon Beach Party down' })).toBeDisabled()
    const selected = within(screen.getByRole('list', { name: 'Collection events' })).getAllByRole('listitem')
    expect(selected.map(item => item.textContent)).toEqual(['1Sunset Jazz', '2Full Moon Beach Party'])
  })

  it('searches the server, debounced, to add an event beyond the first loaded page', async () => {
    const onChange = vi.fn(); const searchEvents = serverSearch()
    render(<Harness onChange={onChange} searchEvents={searchEvents} />)
    await userEvent.type(searchbox(), 'carn')
    await userEvent.click(await screen.findByRole('button', { name: 'Add Liberation Day Carnival' }))
    expect(onChange).toHaveBeenLastCalledWith([140])
    expect(searchEvents).toHaveBeenCalledTimes(1)
    expect(searchEvents).toHaveBeenCalledWith('carn', expect.any(AbortSignal))

    await userEvent.clear(searchbox())
    await userEvent.type(searchbox(), 'jazz')
    await userEvent.click(await screen.findByRole('button', { name: 'Add Sunset Jazz' }))
    expect(onChange).toHaveBeenLastCalledWith([140, 9])
    const selected = within(screen.getByRole('list', { name: 'Collection events' })).getAllByRole('listitem')
    expect(selected.map(item => item.textContent)).toEqual(['1Liberation Day Carnival', '2Sunset Jazz'])
  })

  it('aborts a superseded search', async () => {
    const signals = []
    const searchEvents = vi.fn((term, signal) => { signals.push(signal); return new Promise(() => {}) })
    render(<Harness onChange={vi.fn()} searchEvents={searchEvents} />)
    await userEvent.type(searchbox(), 'sun')
    await waitFor(() => expect(searchEvents).toHaveBeenCalledTimes(1))
    await userEvent.type(searchbox(), 'set')
    await waitFor(() => expect(searchEvents).toHaveBeenCalledTimes(2))
    expect(signals[0].aborted).toBe(true)
    expect(screen.getByText('Searching…')).toBeInTheDocument()
  })

  it('adds the first match on Enter instead of submitting the form', async () => {
    const onChange = vi.fn(); const onSubmit = vi.fn(event => event.preventDefault())
    render(<form onSubmit={onSubmit}><Harness onChange={onChange} /></form>)
    await userEvent.type(searchbox(), 'jazz')
    await screen.findByRole('button', { name: 'Add Sunset Jazz' })
    await userEvent.type(searchbox(), '{Enter}')
    expect(onChange).toHaveBeenLastCalledWith([9])
    expect(onSubmit).not.toHaveBeenCalled()
  })

  it('ignores Enter while an input method is composing', async () => {
    const onChange = vi.fn()
    render(<Harness onChange={onChange} />)
    await userEvent.type(searchbox(), 'jazz')
    await screen.findByRole('button', { name: 'Add Sunset Jazz' })
    fireEvent.keyDown(searchbox(), { key: 'Enter', isComposing: true })
    expect(onChange).not.toHaveBeenCalled()
    fireEvent.keyDown(searchbox(), { key: 'Enter' })
    expect(onChange).toHaveBeenLastCalledWith([9])
  })
})
