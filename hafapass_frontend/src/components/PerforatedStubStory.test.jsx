import { act, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import PerforatedStubStory from './PerforatedStubStory'

const reduceMotion = reduce => vi.stubGlobal('matchMedia', vi.fn(query => ({
  matches: reduce && query === '(prefers-reduced-motion: reduce)', addEventListener: vi.fn(), removeEventListener: vi.fn(),
})))
const setHeight = height => Object.defineProperty(window, 'innerHeight', { configurable: true, value: height })
const initialHeight = window.innerHeight
const event = { title: 'Reef night', starts_at: '2099-10-20T08:00:00Z', timezone: 'Pacific/Guam' }
const story = () => screen.getByRole('region', { name: 'From your phone to the door' })
const ticket = () => story().querySelector('.stub-story-ticket')

afterEach(() => { vi.unstubAllGlobals(); setHeight(initialHeight) })

describe('PerforatedStubStory', () => {
  it.each([
    ['reduced motion', true, 844],
    ['a short screen', false, 500],
  ])('shows the finished, torn ticket with every step under %s', (_case, reduce, height) => {
    reduceMotion(reduce)
    setHeight(height)
    const scroll = vi.spyOn(window, 'addEventListener')
    render(<PerforatedStubStory event={event} />)
    expect(story()).toHaveAttribute('data-step', 'done')
    expect(story()).toHaveAttribute('data-motion', 'off')
    expect(ticket().style.getPropertyValue('--tear')).toBe('')
    expect(scroll.mock.calls.filter(([type]) => type === 'scroll')).toHaveLength(0)
    expect(screen.getAllByRole('heading', { level: 3 }).map(item => item.textContent)).toEqual(['Pick your night', 'Instant QR pass', 'Fast scan at the door'])
    expect(story()).toHaveTextContent('Reef night')
    expect(story()).toHaveTextContent('Admitted')
    scroll.mockRestore()
  })

  it('tears with the scroll, mends when scrolling back, and cleans up', async () => {
    reduceMotion(false)
    setHeight(1000)
    let top = 900
    const view = render(<PerforatedStubStory event={event} />)
    ticket().getBoundingClientRect = () => ({ top })
    await act(async () => { window.dispatchEvent(new Event('scroll')); await new Promise(requestAnimationFrame) })
    expect(ticket().style.getPropertyValue('--tear')).toBe('0.000')
    expect(story()).toHaveAttribute('data-step', '1')
    top = 300
    await act(async () => { window.dispatchEvent(new Event('scroll')); await new Promise(requestAnimationFrame) })
    expect(ticket().style.getPropertyValue('--tear')).toBe('1.000')
    expect(story()).toHaveAttribute('data-step', '3')
    top = 575
    await act(async () => { window.dispatchEvent(new Event('scroll')); await new Promise(requestAnimationFrame) })
    expect(ticket().style.getPropertyValue('--tear')).toBe('0.500')
    expect(story()).toHaveAttribute('data-step', '2')
    const remove = vi.spyOn(window, 'removeEventListener')
    view.unmount()
    expect(remove.mock.calls.filter(([type]) => type === 'scroll')).toHaveLength(1)
    remove.mockRestore()
  })
})
