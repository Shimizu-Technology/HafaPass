import { render, screen } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { FadeUp, StaggerContainer, StaggerItem } from './ScrollReveal'

const state = vi.hoisted(() => ({ inView: false, reduced: false, props: [] }))
vi.mock('framer-motion', async () => {
  const { forwardRef } = await import('react')
  return {
    useInView: () => state.inView,
    useReducedMotion: () => state.reduced,
    motion: { div: forwardRef(({ children, className, ...props }, ref) => {
      state.props.push(props)
      return <div ref={ref} className={className}>{children}</div>
    }) },
  }
})

beforeEach(() => { state.inView = false; state.reduced = false; state.props = [] })

describe('content availability independent of scroll reveals', () => {
  it('keeps content visible while the intersection observer has not fired', () => {
    render(<FadeUp delay={0.1}><button>Buy tickets</button></FadeUp>)
    expect(screen.getByRole('button', { name: 'Buy tickets' })).toBeEnabled()
    expect(state.props[0].initial.opacity).toBe(1)
    expect(state.props[0].animate.opacity).toBe(1)
    render(<StaggerContainer><StaggerItem>Available event</StaggerItem></StaggerContainer>)
    const item = state.props.find(props => props.variants?.resting?.opacity)
    expect(item.variants.resting.opacity).toBe(1)
    expect(item.variants.settled.opacity).toBe(1)
  })

  it('settles with no translation, delay or stagger under reduced motion', () => {
    state.reduced = true
    render(<FadeUp delay={0.5}>Event details</FadeUp>)
    expect(state.props[0]).toMatchObject({ initial: false, animate: { opacity: 1, y: 0 }, transition: { duration: 0, delay: 0 } })
    render(<StaggerContainer><StaggerItem>Available event</StaggerItem></StaggerContainer>)
    const container = state.props.find(props => props.variants?.settled?.transition?.staggerChildren === 0)
    const item = state.props.find(props => props.variants?.resting?.opacity)
    expect(container.initial).toBe(false)
    expect(container.animate).toBe('settled')
    expect(item.variants.resting.y).toBe(0)
    expect(item.variants.settled).toMatchObject({ y: 0, transition: { duration: 0 } })
  })
})
