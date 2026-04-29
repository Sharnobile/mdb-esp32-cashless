import { describe, it, expect, vi } from 'vitest'

// Drive useRuntimeConfig() per-test so we can vary inputs.
let mockPublic: { envName?: string; envColor?: string } = {}
vi.mock('#imports', () => ({
  useRuntimeConfig: () => ({ public: mockPublic }),
}))

import { useEnvironment } from '../useEnvironment'

function withConfig(p: { envName?: string; envColor?: string }) {
  mockPublic = p
  return useEnvironment()
}

describe('useEnvironment', () => {
  describe('isProduction / showBanner', () => {
    it.each([
      [undefined],
      [''],
      ['  '],
      ['prod'],
      ['PROD'],
      ['Production'],
      ['production'],
    ])('treats %j as production', (envName) => {
      const env = withConfig({ envName })
      expect(env.isProduction).toBe(true)
      expect(env.showBanner).toBe(false)
      expect(env.envName).toBe('')
    })

    it.each(['dev', 'test', 'staging', 'qa', 'my-laptop'])(
      'treats %s as non-production',
      (envName) => {
        const env = withConfig({ envName })
        expect(env.isProduction).toBe(false)
        expect(env.showBanner).toBe(true)
      },
    )

    it('uppercases the env name when shown', () => {
      expect(withConfig({ envName: 'dev' }).envName).toBe('DEV')
      expect(withConfig({ envName: 'Test' }).envName).toBe('TEST')
      expect(withConfig({ envName: '  staging  ' }).envName).toBe('STAGING')
    })
  })

  describe('envColor', () => {
    it.each(['red', 'amber', 'orange', 'purple', 'blue'])(
      'accepts valid color %s',
      (color) => {
        expect(withConfig({ envName: 'dev', envColor: color }).envColor).toBe(color)
      },
    )

    it('falls back to amber for empty color', () => {
      expect(withConfig({ envName: 'dev', envColor: '' }).envColor).toBe('amber')
    })

    it('falls back to amber for missing color', () => {
      expect(withConfig({ envName: 'dev' }).envColor).toBe('amber')
    })

    it('falls back to amber for unknown color', () => {
      expect(withConfig({ envName: 'dev', envColor: 'neon' }).envColor).toBe('amber')
    })

    it('is case-insensitive on color input', () => {
      expect(withConfig({ envName: 'dev', envColor: 'RED' }).envColor).toBe('red')
    })
  })
})
