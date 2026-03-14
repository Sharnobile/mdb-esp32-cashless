import type { ClassValue } from "clsx"
import { clsx } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

/**
 * i18n-aware timeAgo — pass the `t` function from useI18n().
 * Falls back to English if no `t` provided.
 */
export function timeAgo(dt: string | null | undefined, t?: (key: string, params?: Record<string, any>) => string): string {
  if (!dt) return '—'
  const seconds = Math.floor((Date.now() - new Date(dt).getTime()) / 1000)
  if (t) {
    if (seconds < 60) return t('time.justNow')
    const minutes = Math.floor(seconds / 60)
    if (minutes < 60) return t('time.minutesAgo', { count: minutes })
    const hours = Math.floor(minutes / 60)
    if (hours < 24) return t('time.hoursAgo', { count: hours })
    const days = Math.floor(hours / 24)
    return t('time.daysAgo', { count: days })
  }
  // Fallback without i18n
  if (seconds < 60) return 'just now'
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(hours / 24)
  return `${days}d ago`
}

export function formatCurrency(amount: number | null | undefined, locale?: string): string {
  if (amount == null) return '—'
  return new Intl.NumberFormat(locale ?? 'en-US', { style: 'currency', currency: 'EUR' }).format(amount)
}

export function formatDate(dt: string | null | undefined, locale?: string): string {
  if (!dt) return '\u2014'
  return new Date(dt).toLocaleDateString(locale, {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
  })
}

export function formatDateTime(dt: string | null | undefined, locale?: string): string {
  if (!dt) return '\u2014'
  return new Date(dt).toLocaleString(locale, {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}
