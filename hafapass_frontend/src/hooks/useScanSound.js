import { useCallback, useEffect, useRef, useState } from 'react'

export const SCANNER_SOUND_KEY = 'hafapass_scanner_sound'

const readSoundPreference = () => {
  try { return window.localStorage.getItem(SCANNER_SOUND_KEY) !== 'off' } catch { return true }
}

// [frequency Hz, start offset s, duration s, waveform]
const PATTERNS = {
  admit: [[880, 0, 0.16, 'sine']],
  refuse: [[220, 0, 0.18, 'square'], [220, 0.28, 0.18, 'square']],
}

// Door feedback tones. Browsers (iOS especially) only allow audio from a
// context created or resumed during a tap, so call primeSound from the
// "Start camera" or Sound tap before playScanSound can be heard.
export default function useScanSound() {
  const [soundOn, setSoundOn] = useState(readSoundPreference)
  const soundOnRef = useRef(soundOn)
  const contextRef = useRef(null)
  useEffect(() => { soundOnRef.current = soundOn }, [soundOn])

  const primeSound = useCallback(() => {
    // Safari 17+: play through the ringer/silent switch like media playback.
    try { if (navigator.audioSession) navigator.audioSession.type = 'playback' } catch { /* Optional browser feature. */ }
    const AudioContextClass = window.AudioContext || window.webkitAudioContext
    if (!AudioContextClass) return
    try {
      if (!contextRef.current || contextRef.current.state === 'closed') contextRef.current = new AudioContextClass()
      Promise.resolve(contextRef.current.resume?.()).catch(() => {})
    } catch { contextRef.current = null /* Audio is optional; the screen still shows the result. */ }
  }, [])

  const playScanSound = useCallback(kind => {
    const context = contextRef.current
    const pattern = PATTERNS[kind]
    if (!soundOnRef.current || !context || !pattern) return
    try {
      if (context.state !== 'running') Promise.resolve(context.resume?.()).catch(() => {})
      const start = context.currentTime + 0.01
      for (const [frequency, offset, duration, type] of pattern) {
        const oscillator = context.createOscillator()
        const gain = context.createGain()
        const at = start + offset
        oscillator.type = type
        oscillator.frequency.setValueAtTime(frequency, at)
        gain.gain.setValueAtTime(0.0001, at)
        gain.gain.exponentialRampToValueAtTime(0.6, at + 0.01)
        gain.gain.exponentialRampToValueAtTime(0.0001, at + duration)
        oscillator.connect(gain)
        gain.connect(context.destination)
        oscillator.start(at)
        oscillator.stop(at + duration + 0.02)
      }
    } catch { /* Audio is optional; the screen still shows the result. */ }
  }, [])

  const toggleSound = useCallback(() => {
    const next = !soundOnRef.current
    soundOnRef.current = next
    setSoundOn(next)
    try { window.localStorage.setItem(SCANNER_SOUND_KEY, next ? 'on' : 'off') } catch { /* Preference lasts this visit. */ }
    if (next) primeSound()
  }, [primeSound])

  useEffect(() => () => {
    const context = contextRef.current
    contextRef.current = null
    try { Promise.resolve(context?.close?.()).catch(() => {}) } catch { /* Already closed. */ }
  }, [])

  return { soundOn, toggleSound, primeSound, playScanSound }
}
