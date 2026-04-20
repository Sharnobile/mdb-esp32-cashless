#!/usr/bin/env node
/**
 * Brand asset generator.
 *
 * Renders brand/logo-mark.svg (rounded, for web) and brand/logo-mark-bleed.svg
 * (full-bleed square, for iOS/Android where the OS applies its own mask) into
 * all required PNG sizes and copies the favicon SVG to the frontend.
 *
 * Single source of truth: the two SVG files in this directory. Edit them and
 * run `npm run generate` — do NOT hand-edit the generated PNGs.
 */

import { Resvg } from '@resvg/resvg-js'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const repo = resolve(here, '..')

const MASTER = readFileSync(resolve(here, 'logo-mark.svg'), 'utf8')
const BLEED = readFileSync(resolve(here, 'logo-mark-bleed.svg'), 'utf8')
const DEV = readFileSync(resolve(here, 'logo-mark-dev.svg'), 'utf8')
const DEV_BLEED = readFileSync(resolve(here, 'logo-mark-dev-bleed.svg'), 'utf8')

/** Render an SVG string to a PNG Buffer at `size` px (square). */
function renderPng(svg, size) {
  const resvg = new Resvg(svg, {
    fitTo: { mode: 'width', value: size },
    background: 'rgba(0,0,0,0)',
    // No system fonts: the dev variant draws "DEV" as explicit SVG paths
    // (see brand/logo-mark-dev.svg) so output is byte-deterministic across
    // platforms — macOS dev machines and Linux CI produce identical PNGs.
  })
  return resvg.render().asPng()
}

function writeFile(relPath, buffer) {
  const abs = resolve(repo, relPath)
  mkdirSync(dirname(abs), { recursive: true })
  writeFileSync(abs, buffer)
  const kind = typeof buffer === 'string' ? 'svg' : `${buffer.length} bytes`
  console.log(`  ${relPath}  (${kind})`)
}

function writePng(relPath, svg, size) {
  writeFile(relPath, renderPng(svg, size))
}

console.log('\nBrand assets\n============')

console.log('\niOS AppIcon (full-bleed 1024×1024)')
writePng('ios/VMflow/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png', BLEED, 1024)
writePng('ios/VMflow/Resources/Assets.xcassets/AppIcon-Debug.appiconset/AppIcon-Debug.png', DEV_BLEED, 1024)

console.log('\nAndroid launcher icons (legacy single PNG per density, main flavor)')
writePng('Android/app/src/main/res/mipmap-mdpi/ic_launcher.png', MASTER, 48)
writePng('Android/app/src/main/res/mipmap-hdpi/ic_launcher.png', MASTER, 72)
writePng('Android/app/src/main/res/mipmap-xhdpi/ic_launcher.png', MASTER, 96)
writePng('Android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png', MASTER, 144)
writePng('Android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png', MASTER, 192)

console.log('\nAndroid launcher icons (debug flavor, with orange dev band)')
writePng('Android/app/src/debug/res/mipmap-mdpi/ic_launcher.png', DEV, 48)
writePng('Android/app/src/debug/res/mipmap-hdpi/ic_launcher.png', DEV, 72)
writePng('Android/app/src/debug/res/mipmap-xhdpi/ic_launcher.png', DEV, 96)
writePng('Android/app/src/debug/res/mipmap-xxhdpi/ic_launcher.png', DEV, 144)
writePng('Android/app/src/debug/res/mipmap-xxxhdpi/ic_launcher.png', DEV, 192)

console.log('\nPWA / web icons')
// Standard PWA icons (rounded, shown as-is on iOS home screen)
writePng('management-frontend/public/icons/icon-192.png', MASTER, 192)
writePng('management-frontend/public/icons/icon-512.png', MASTER, 512)
// Maskable: Android safe-zone crops ~20% margin, so use the bleed variant and
// let Android apply its own shape mask.
writePng('management-frontend/public/icons/icon-maskable-192.png', BLEED, 192)
writePng('management-frontend/public/icons/icon-maskable-512.png', BLEED, 512)
// Apple touch icon (iOS also applies a mask; use bleed)
writePng('management-frontend/public/apple-touch-icon.png', BLEED, 180)
// Classic favicons for older browsers / pinned tabs
writePng('management-frontend/public/favicon-16.png', MASTER, 16)
writePng('management-frontend/public/favicon-32.png', MASTER, 32)
writePng('management-frontend/public/favicon-48.png', MASTER, 48)
// SVG favicon (modern browsers)
writeFile('management-frontend/public/favicon.svg', MASTER)

console.log('\nDone.\n')
