import { describe, it, expect } from 'vitest'
import { companyActivityLevel, isDeviceOnline } from '../usePlatformAdmin'

describe('companyActivityLevel', () => {
  const now = new Date('2026-06-30T12:00:00Z')

  it('returns active when last sale is within 7 days', () => {
    expect(companyActivityLevel('2026-06-28T12:00:00Z', now)).toBe('active')
  })
  it('returns idle when last sale is 8–30 days ago', () => {
    expect(companyActivityLevel('2026-06-10T12:00:00Z', now)).toBe('idle')
  })
  it('returns dead when last sale is older than 30 days', () => {
    expect(companyActivityLevel('2026-04-01T12:00:00Z', now)).toBe('dead')
  })
  it('returns dead when there was never a sale', () => {
    expect(companyActivityLevel(null, now)).toBe('dead')
  })
})

describe('isDeviceOnline', () => {
  it('treats online and transient non-offline states as online', () => {
    expect(isDeviceOnline('online')).toBe(true)
    expect(isDeviceOnline('ota_updating')).toBe(true)
  })
  it('treats offline and null/empty as not online', () => {
    expect(isDeviceOnline('offline')).toBe(false)
    expect(isDeviceOnline(null)).toBe(false)
    expect(isDeviceOnline('')).toBe(false)
  })
})
