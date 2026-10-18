import { useState } from 'react'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import CollectionEventPicker from './CollectionEventPicker'

const events = [
  { id: 6, title: 'Full Moon Beach Party', organizer_name: 'Island Nights Promotions', status: 'published' },
  { id: 9, title: 'Sunset Jazz', organizer_name: 'Island Nights Promotions', status: 'draft' },
  { id: 12, title: 'Chamorro Food Fest', organizer_name: 'Guam Eats', status: 'published' },
]

function Harness({ onChange, initial = [] }) {
  const [value, setValue] = useState(initial)
  return <CollectionEventPicker events={events} value={value} onChange={next => { setValue(next); onChange(next) }} />
}

describe('CollectionEventPicker', () => {
  it('shows an empty state until events are added', () => {
    render(<Harness onChange={vi.fn()} />)
    expect(screen.getByText(/No events added yet/)).toBeInTheDocument()
  })

  it('builds, reorders and trims the ordered event id list', async () => {
    const onChange = vi.fn()
    render(<Harness onChange={onChange} />)
    await userEvent.type(screen.getByRole('searchbox', { name: 'Search events to add' }), 'food')
    const available = within(screen.getByRole('list', { name: 'Events available to add' }))
    expect(available.queryByText('Sunset Jazz')).not.toBeInTheDocument()
    await userEvent.click(available.getByRole('button', { name: 'Add Chamorro Food Fest' }))
    await userEvent.clear(screen.getByRole('searchbox', { name: 'Search events to add' }))
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

  it('adds the first match on Enter instead of submitting the form', async () => {
    const onChange = vi.fn(); const onSubmit = vi.fn(event => event.preventDefault())
    render(<form onSubmit={onSubmit}><Harness onChange={onChange} /></form>)
    await userEvent.type(screen.getByRole('searchbox', { name: 'Search events to add' }), 'jazz{Enter}')
    expect(onChange).toHaveBeenLastCalledWith([9])
    expect(onSubmit).not.toHaveBeenCalled()
  })
})
