import { Capacitor } from '@capacitor/core'

export const isNative = () => Capacitor.isNativePlatform()
export const isWeb = () => !Capacitor.isNativePlatform()
export const getPlatform = () => Capacitor.getPlatform() as 'ios' | 'android' | 'web'
