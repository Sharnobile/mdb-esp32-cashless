import { marked } from 'marked'
import DOMPurify from 'dompurify'

// Configure marked once at module load.
// - gfm: enable GitHub-flavored Markdown (tables, strikethrough, task lists)
// - breaks: treat single newlines as <br>, matching how GitHub renders release notes
// - async: false keeps parse synchronous so we can return a string
marked.setOptions({
  gfm: true,
  breaks: true,
  async: false,
})

/**
 * Render a Markdown string to sanitized HTML.
 * Safe to use with `v-html` — output is passed through DOMPurify's default profile,
 * which removes <script>, inline event handlers, and javascript: URLs.
 *
 * Returns an empty string for null/undefined/empty input.
 */
export function renderMarkdown(source: string | null | undefined): string {
  if (!source) return ''
  // DOMPurify needs a DOM window; on the server we return an empty string.
  // The changelog modal is client-only (gated by user click), so SSR never hits this path in
  // normal use — this guard is purely defensive against accidental server-side imports.
  if (typeof window === 'undefined') return ''
  const raw = marked.parse(source) as string
  return DOMPurify.sanitize(raw, { USE_PROFILES: { html: true } })
}
