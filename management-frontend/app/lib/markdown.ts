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
  const raw = marked.parse(source) as string
  return DOMPurify.sanitize(raw, { USE_PROFILES: { html: true } })
}
