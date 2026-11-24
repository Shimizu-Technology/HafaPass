import { act, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { FadeUp, StaggerContainer, StaggerItem } from './ScrollReveal'

let observers = []
class FakeIntersectionObserver {
  constructor(callback) {
    this.callback = callback
    this.elements = []
    observers.push(this)
  }
  observe(element) { this.elements.push(element) }
  disconnect() {}
}

const reduceMotion = reduce => vi.stubGlobal('matchMedia', vi.fn(query => ({
  matches: reduce && query === '(prefers-reduced-motion: reduce)',
  addEventListener: vi.fn(),
  removeEventListener: vi.fn(),
})))

beforeEach(() => {
  observers = []
  reduceMotion(false)
  vi.stubGlobal('IntersectionObserver', FakeIntersectionObserver)
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('content availability independent of scroll reveals', () => {
  it('keeps content visible while the intersection observer has not fired, then settles on view', () => {
    const { container } = render(
      <>
        <FadeUp delay={0.1}><button>Buy tickets</button></FadeUp>
        <StaggerContainer><StaggerItem>Available event</StaggerItem></StaggerContainer>
      </>,
    )
    expect(screen.getByRole('button', { name: 'Buy tickets' })).toBeEnabled()
    expect(screen.getByText('Available event')).toBeVisible()
    const reveal = container.querySelector('.scroll-reveal')
    const stagger = container.querySelector('.scroll-reveal-stagger')
    expect(reveal).toHaveAttribute('data-reveal', 'resting')
    expect(stagger).toHaveAttribute('data-reveal', 'resting')

    act(() => {
      observers.forEach(observer => observer.callback([{ isIntersecting: true }]))
    })
    expect(reveal).toHaveAttribute('data-reveal', 'settled')
    expect(stagger).toHaveAttribute('data-reveal', 'settled')
  })

  it('settles immediately with no translation, delay or stagger under reduced motion', () => {
    reduceMotion(true)
    const { container } = render(
      <>
        <FadeUp delay={0.5}>Event details</FadeUp>
        <StaggerContainer><StaggerItem>Available event</StaggerItem></StaggerContainer>
      </>,
    )
    const reveal = container.querySelector('.scroll-reveal')
    const stagger = container.querySelector('.scroll-reveal-stagger')
    const item = container.querySelector('.scroll-reveal-item')
    expect(reveal).toHaveAttribute('data-reveal', 'settled')
    expect(reveal.style.transform).toBe('none')
    expect(reveal.style.transitionDuration).toBe('0ms')
    expect(reveal.style.transitionDelay).toBe('')
    expect(stagger).toHaveAttribute('data-reveal', 'settled')
    expect(stagger).toHaveAttribute('data-reduced-motion', 'true')
    expect(item.style.transform).toBe('none')
    expect(item.style.transitionDuration).toBe('0ms')
  })
})
