import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import BarList from './BarList'
import DailyColumnChart from './DailyColumnChart'
import { axisTicks, formatDay, labelIndexes, niceMax } from './chartScale'

describe('chart scale helpers', () => {
  it('rounds axes to clean values', () => {
    expect(niceMax(37)).toBe(50)
    expect(axisTicks(37)).toEqual([0, 20, 40])
    expect(axisTicks(3, { integer: true })).toEqual([0, 2, 4])
    expect(axisTicks(1, { integer: true })).toEqual([0, 1])
    expect(axisTicks(0)).toEqual([0, 0.25, 0.5, 0.75, 1])
  })

  it('formats calendar days without shifting them into the browser timezone', () => {
    expect(formatDay('2026-10-02')).toBe('Oct 2')
  })

  it('always labels the first and last day', () => {
    expect(labelIndexes(1, 5)).toEqual([0])
    expect(labelIndexes(30, 4)).toEqual([0, 10, 19, 29])
  })
})

describe('DailyColumnChart', () => {
  const days = [
    { date: '2026-10-01', value: 2 },
    { date: '2026-10-02', value: 0 },
    { date: '2026-10-03', value: 5 },
  ]

  it('summarizes the series for screen readers and labels the busiest day', () => {
    const { container } = render(<DailyColumnChart days={days} label="Tickets sold per day" unitLabel="tickets" integer />)
    expect(screen.getByRole('group', { name: /Tickets sold per day\. 3 days from Oct 1 to Oct 3\. Total 7\. Busiest day Oct 3 with 5\./ })).toBeInTheDocument()
    expect(container.querySelectorAll('path')).toHaveLength(3)
    expect(container.querySelector('svg')).toHaveTextContent('5')
  })

  it('reads each day with the arrow keys', () => {
    render(<DailyColumnChart days={days} label="Tickets sold per day" unitLabel="tickets" integer />)
    const chart = screen.getByRole('group')
    fireEvent.focus(chart)
    expect(screen.getByText('Saturday, October 3: 5 tickets')).toBeInTheDocument()
    fireEvent.keyDown(chart, { key: 'ArrowLeft' })
    expect(screen.getByText('Friday, October 2: 0 tickets')).toBeInTheDocument()
    fireEvent.keyDown(chart, { key: 'Home' })
    expect(screen.getByText('Thursday, October 1: 2 tickets')).toBeInTheDocument()
  })

  it('draws a single day without stretching the column', () => {
    const { container } = render(<DailyColumnChart days={[{ date: '2026-10-03', value: 4 }]} label="Sales" formatValue={value => `$${value}`} />)
    expect(screen.getByRole('group', { name: /1 day from Oct 3 to Oct 3/ })).toBeInTheDocument()
    const path = container.querySelector('path').getAttribute('d')
    const xs = [...path.matchAll(/[MH](\d+(?:\.\d+)?)/g)].map(match => Number(match[1]))
    expect(Math.max(...xs) - Math.min(...xs)).toBeLessThanOrEqual(24)
  })
})

describe('BarList', () => {
  it('prints every value and scales bars to the largest', () => {
    const { container } = render(<BarList label="Tickets by channel" rows={[
      { key: 'online', label: 'Online', value: 10, detail: '$250.00' },
      { key: 'door', label: 'Box office', value: 5 },
      { key: 'guest', label: 'Guest list', value: 0 },
    ]} />)
    const list = screen.getByRole('list', { name: 'Tickets by channel' })
    expect(list).toHaveTextContent('Online10 · $250.00')
    const bars = container.querySelectorAll('.bg-brand-500')
    expect(bars).toHaveLength(2)
    expect(bars[0].style.width).toBe('100%')
    expect(bars[1].style.width).toBe('50%')
  })

  it('shows the empty message when nothing has a value', () => {
    render(<BarList label="Sources" rows={[{ key: 'a', label: 'Direct', value: 0 }]} emptyText="No visits recorded yet." />)
    expect(screen.getByText('No visits recorded yet.')).toBeInTheDocument()
    expect(screen.queryByRole('list')).not.toBeInTheDocument()
  })
})
