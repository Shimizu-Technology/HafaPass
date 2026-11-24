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

afterEach(() => { vi.unstubAllGlobals(); setHeight(initialHeight) })

describe('PerforatedStubStory', () => {
  it.each([
    ['reduced motion', true, 844],
    ['a short screen (< 680px)', false, 667],
  ])('shows the straight finished ticket with vector QR and every step under %s', (_case, reduce, height) => {
    reduceMotion(reduce)
    setHeight(height)
    const scroll = vi.spyOn(window, 'addEventListener')
    render(<PerforatedStubStory event={event} />)
    expect(story()).toHaveAttribute('data-mode', 'still')
    expect(story()).toHaveAttribute('data-step', 'done')
    expect(story()).toHaveAttribute('data-motion', 'off')
    expect(scroll.mock.calls.filter(([type]) => type === 'scroll')).toHaveLength(0)

    const stub = screen.getByTestId('stub-story-stub')
    expect(stub.style.transform).toBe('translate3d(0, 16px, 0)')
    expect(stub.style.transform).not.toContain('rotate')
    expect(screen.getByTestId('stub-story-admitted').style.transform).toBe('none')

    expect(screen.getAllByRole('heading', { level: 3 }).map(item => item.textContent)).toEqual([
      'Pick your night',
      'Instant QR pass',
      'Fast scan at the door',
    ])
    expect(story()).toHaveTextContent('Reef night')
    expect(story()).toHaveTextContent('Admitted')
    scroll.mockRestore()
  })

  it('activates live pinned mode on tall viewports and cleans up scroll listeners', async () => {
    reduceMotion(false)
    setHeight(900)
    const view = render(<PerforatedStubStory event={event} />)
    expect(story()).toHaveAttribute('data-mode', 'live')
    expect(story()).toHaveAttribute('data-motion', 'on')

    await act(async () => {
      window.dispatchEvent(new Event('scroll'))
      await new Promise(requestAnimationFrame)
    })

    const remove = vi.spyOn(window, 'removeEventListener')
    view.unmount()
    expect(remove.mock.calls.filter(([type]) => type === 'scroll')).toHaveLength(1)
    remove.mockRestore()
  })
})
