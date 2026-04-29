import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'

let mockPublic: { envName?: string; envColor?: string } = {}
// useEnvironment imports useRuntimeConfig from '#imports', which the alias in
// vitest.config.ts resolves to app/test-helpers/nuxt-stubs.ts. Mocking '#imports'
// here intercepts that — so when the component imports useEnvironment from
// '@/composables/useEnvironment' (a real file), useEnvironment's call to
// useRuntimeConfig() hits the mock below.
vi.mock('#imports', () => ({
  useRuntimeConfig: () => ({ public: mockPublic }),
}))

import EnvironmentBanner from '../EnvironmentBanner.vue'

function mountWith(p: { envName?: string; envColor?: string }) {
  mockPublic = p
  return mount(EnvironmentBanner)
}

describe('EnvironmentBanner', () => {
  it('renders nothing in production (empty envName)', () => {
    const w = mountWith({})
    expect(w.find('[data-testid="env-banner"]').exists()).toBe(false)
  })

  it('renders nothing when envName is "prod"', () => {
    const w = mountWith({ envName: 'prod' })
    expect(w.find('[data-testid="env-banner"]').exists()).toBe(false)
  })

  it('renders the banner with uppercased env name for non-prod', () => {
    const w = mountWith({ envName: 'dev' })
    expect(w.text()).toContain('DEV')
    expect(w.find('[data-testid="env-banner"]').exists()).toBe(true)
  })

  it.each([
    ['red',    'bg-red-600'],
    ['amber',  'bg-amber-500'],
    ['orange', 'bg-orange-500'],
    ['purple', 'bg-purple-600'],
    ['blue',   'bg-blue-600'],
  ])('applies bg class for color %s', (color, cls) => {
    const w = mountWith({ envName: 'dev', envColor: color })
    expect(w.find('[data-testid="env-banner"]').classes()).toContain(cls)
  })

  it('falls back to amber for unknown color', () => {
    const w = mountWith({ envName: 'dev', envColor: 'neon' })
    expect(w.find('[data-testid="env-banner"]').classes()).toContain('bg-amber-500')
  })

  it('is sticky to the top of its scroll container', () => {
    const w = mountWith({ envName: 'dev' })
    const cls = w.find('[data-testid="env-banner"]').classes()
    expect(cls).toContain('sticky')
    expect(cls).toContain('top-0')
    expect(cls).toContain('z-50')
  })
})
