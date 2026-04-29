import { useRuntimeConfig } from '#imports'

export type ColorKey = 'red' | 'amber' | 'orange' | 'purple' | 'blue'

const VALID_COLORS: readonly ColorKey[] = ['red', 'amber', 'orange', 'purple', 'blue'] as const
const PROD_ALIASES = new Set(['prod', 'production'])

export interface EnvironmentInfo {
  envName: string         // uppercased when shown, '' when production
  envColor: ColorKey      // validated, defaults to 'amber'
  isProduction: boolean
  showBanner: boolean
}

export function useEnvironment(): EnvironmentInfo {
  const config = useRuntimeConfig()
  const rawName = String(config.public.envName ?? '').trim()
  const rawColor = String(config.public.envColor ?? '').trim().toLowerCase()

  const isProduction = rawName === '' || PROD_ALIASES.has(rawName.toLowerCase())
  const envName = isProduction ? '' : rawName.toUpperCase()

  const envColor: ColorKey = (VALID_COLORS as readonly string[]).includes(rawColor)
    ? (rawColor as ColorKey)
    : 'amber'

  return {
    envName,
    envColor,
    isProduction,
    showBanner: !isProduction,
  }
}
