import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { Typewriter } from '@/utils/typewriter'

describe('Typewriter', () => {
  let onConsume: ReturnType<typeof vi.fn>
  let tw: Typewriter

  beforeEach(() => {
    vi.useFakeTimers()
    onConsume = vi.fn()
    tw = new Typewriter(onConsume)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('add pushes characters to queue and start consumes', () => {
    tw.add('ab')
    tw.start()
    vi.advanceTimersByTime(500)
    expect(onConsume).toHaveBeenCalled()
  })

  it('add ignores empty string', () => {
    tw.add('')
    tw.start()
    vi.advanceTimersByTime(500)
    // Should still call at least once for consume
  })

  it('done flushes remaining chars', () => {
    tw.add('hello')
    tw.start()
    vi.advanceTimersByTime(50) // consume one char
    tw.done()
    // Remaining chars flushed in one call
    const calls = onConsume.mock.calls.map(c => c[0]).join('')
    expect(calls).toContain('hello')
  })

  it('done stops consuming', () => {
    tw.add('abc')
    tw.start()
    tw.done()
    const callCount = onConsume.mock.calls.length
    vi.advanceTimersByTime(1000)
    expect(onConsume.mock.calls.length).toBe(callCount)
  })

  it('dynamicSpeed caps at 200ms', () => {
    tw.add('a')
    expect(tw.dynamicSpeed()).toBe(200)
  })

  it('dynamicSpeed decreases with more chars', () => {
    tw.add('a'.repeat(50))
    const speed = tw.dynamicSpeed()
    expect(speed).toBeLessThan(200)
    expect(speed).toBeGreaterThan(0)
  })

  it('consume from empty queue does nothing', () => {
    tw.start()
    vi.advanceTimersByTime(300)
    // onConsume may be called with undefined from shift
    // but should not crash
  })
})
