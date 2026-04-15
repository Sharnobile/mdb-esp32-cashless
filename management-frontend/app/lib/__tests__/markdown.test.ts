import { describe, it, expect } from 'vitest'
import { renderMarkdown } from '../markdown'

describe('renderMarkdown', () => {
  it('renders basic markdown to HTML', () => {
    const html = renderMarkdown('# Hello\n\n**bold** and *italic*')
    expect(html).toContain('<h1')
    expect(html).toContain('Hello')
    expect(html).toContain('<strong>bold</strong>')
    expect(html).toContain('<em>italic</em>')
  })

  it('renders GitHub-style bullet lists', () => {
    const html = renderMarkdown('- first\n- second')
    expect(html).toContain('<ul>')
    expect(html).toContain('<li>first</li>')
    expect(html).toContain('<li>second</li>')
  })

  it('converts single newlines to <br> (GFM breaks)', () => {
    const html = renderMarkdown('line one\nline two')
    expect(html).toContain('<br>')
  })

  it('strips <script> tags', () => {
    const html = renderMarkdown('safe <script>alert(1)</script> text')
    expect(html).not.toContain('<script')
    expect(html).not.toContain('alert(1)')
  })

  it('strips inline event handlers', () => {
    const html = renderMarkdown('<a href="https://example.com" onclick="alert(1)">link</a>')
    expect(html).not.toContain('onclick')
  })

  it('strips javascript: URLs', () => {
    const html = renderMarkdown('[evil](javascript:alert(1))')
    expect(html).not.toMatch(/href=["']javascript:/)
  })

  it('returns empty string for empty input', () => {
    expect(renderMarkdown('')).toBe('')
    expect(renderMarkdown(null as unknown as string)).toBe('')
    expect(renderMarkdown(undefined as unknown as string)).toBe('')
  })
})
