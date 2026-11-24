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

afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); setHeight(initialHeight) })

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
    vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue(null)
    let top = 0
    vi.spyOn(HTMLElement.prototype, 'offsetHeight', 'get').mockImplementation(function () {
      return this.classList.contains('stub-story-sticky') ? 900 : 1900
    })
    vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockImplementation(function () {
      return { top: this.getAttribute('data-testid') === 'perforated-stub-story' ? top : 0, left: 0, width: 390, height: 1900, right: 390, bottom: 1900 }
    })
    const view = render(<PerforatedStubStory event={event} />)
    expect(story()).toHaveAttribute('data-mode', 'live')
    expect(story()).toHaveAttribute('data-motion', 'on')

    expect(story()).toHaveAttribute('data-step', '1')
    const canvas = story().querySelector('canvas')
    const qr = canvas.nextElementSibling
    expect(qr.style.opacity).toBe('0')
    expect(screen.getByTestId('stub-story-admitted').style.opacity).toBe('0')
    const scrollToProgress = async value => {
      top = -1000 * value
      await act(async () => {
        window.dispatchEvent(new Event('scroll'))
        await new Promise(resolve => setTimeout(resolve, 1200))
      })
    }
    await scrollToProgress(0.5)
    expect(story()).toHaveAttribute('data-step', '2')
    expect(story().querySelectorAll('.stub-story-step')[0]).toHaveAttribute('data-done', 'true')
    expect(screen.getByTestId('stub-story-stub').style.transform).toContain('rotate')
    expect(qr.style.opacity).toBe('0')
    expect(screen.getByTestId('stub-story-admitted').style.opacity).toBe('0')
    await scrollToProgress(1)
    expect(story()).toHaveAttribute('data-step', '3')
    expect(qr.style.opacity).toBe('1')
    expect(canvas.style.opacity).toBe('0')
    expect(screen.getByTestId('stub-story-admitted').style.opacity).toBe('1')
    expect(screen.getByTestId('stub-story-admitted').style.transform).toBe('none')
    expect(screen.getByTestId('stub-story-stub').style.transform).toBe('translate3d(0, 16px, 0)')

    const remove = vi.spyOn(window, 'removeEventListener')
    view.unmount()
    expect(remove.mock.calls.filter(([type]) => type === 'scroll')).toHaveLength(1)
    remove.mockRestore()
  })
})
