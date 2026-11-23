import { act, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import PerforatedStubStory from './PerforatedStubStory'

const reduceMotion = reduce => vi.stubGlobal('matchMedia', vi.fn(query => ({
  matches: reduce && query === '(prefers-reduced-motion: reduce)',
  addEventListener: vi.fn(),
  removeEventListener: vi.fn(),
})))
const setHeight = height => Object.defineProperty(window, 'innerHeight', { configurable: true, value: height })
const initialHeight = window.innerHeight
const event = { title: 'Reef night', starts_at: '2099-10-20T08:00:00Z', timezone: 'Pacific/Guam' }
const story = () => screen.getByRole('region', { name: 'From your phone to the door' })

afterEach(() => { vi.unstubAllGlobals(); setHeight(initialHeight) })

describe('PerforatedStubStory', () => {
  it.each([
    ['reduced motion', true, 844],
    ['a short screen', false, 500],
  ])('shows the unpinned finished ticket with every step under %s', (_case, reduce, height) => {
    reduceMotion(reduce)
    setHeight(height)
    const scroll = vi.spyOn(window, 'addEventListener')
    render(<PerforatedStubStory event={event} />)
    expect(story()).toHaveAttribute('data-mode', 'still')
    expect(story()).toHaveAttribute('data-step', 'done')
    expect(story()).toHaveAttribute('data-motion', 'off')
    expect(scroll.mock.calls.filter(([type]) => type === 'scroll')).toHaveLength(0)
    expect(screen.getAllByRole('heading', { level: 3 }).map(item => item.textContent)).toEqual(['Pick your night', 'Instant QR pass', 'Fast scan at the door'])
    expect(story()).toHaveTextContent('Reef night')
    expect(story()).toHaveTextContent('Admitted')
    scroll.mockRestore()
  })

  it('pins in live mode, updates direct transforms on scroll without --tear, and cleans up', async () => {
    reduceMotion(false)
    setHeight(900)
    const view = render(<PerforatedStubStory event={event} />)
    const sec = story()
    const sticky = sec.querySelector('.stub-story-sticky')
    const stub = sec.querySelector('.stub-story-stub-live')

    expect(sec).toHaveAttribute('data-mode', 'live')
    expect(sec).toHaveAttribute('data-motion', 'on')

    Object.defineProperty(sec, 'offsetHeight', { configurable: true, value: 2000 })
    Object.defineProperty(sticky, 'offsetHeight', { configurable: true, value: 800 })
    let top = 0
    sec.getBoundingClientRect = () => ({ top })

    await act(async () => { window.dispatchEvent(new Event('scroll')); await new Promise(r => setTimeout(r, 450)) })
    expect(sec).toHaveAttribute('data-step', '1')
    expect(stub.style.transform).toContain('translate3d(0, 0')

    top = -1200
    await act(async () => { window.dispatchEvent(new Event('scroll')); await new Promise(r => setTimeout(r, 450)) })
    expect(sec).toHaveAttribute('data-step', '3')
    expect(stub.style.transform).not.toContain('translate3d(0, 0.00px')

    const remove = vi.spyOn(window, 'removeEventListener')
    view.unmount()
    expect(remove.mock.calls.filter(([type]) => type === 'scroll')).toHaveLength(1)
    remove.mockRestore()
  })
})
