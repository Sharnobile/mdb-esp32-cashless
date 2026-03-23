/**
 * Simple fuzzy search: checks if all characters of the query appear
 * in order within the target string (case-insensitive).
 * Returns true if it matches, false otherwise.
 */
export function fuzzyMatch(query: string, target: string): boolean {
  const q = query.toLowerCase()
  const t = target.toLowerCase()
  let qi = 0
  for (let ti = 0; ti < t.length && qi < q.length; ti++) {
    if (t[ti] === q[qi]) qi++
  }
  return qi === q.length
}

/**
 * Fuzzy filter: filters an array of items by matching the query
 * against one or more string fields.
 */
export function fuzzyFilter<T>(
  items: T[],
  query: string,
  fields: ((item: T) => string | null | undefined)[],
): T[] {
  const q = query.trim()
  if (!q) return items
  return items.filter(item =>
    fields.some(fn => {
      const val = fn(item)
      return val ? fuzzyMatch(q, val) : false
    }),
  )
}
