export function useTableSort<K extends string>(defaultKey: K, defaultDir: 'asc' | 'desc' = 'asc') {
  const sortKey = ref<K>(defaultKey)
  const sortDir = ref<'asc' | 'desc'>(defaultDir)

  function toggleSort(key: K) {
    if (sortKey.value === key) {
      sortDir.value = sortDir.value === 'asc' ? 'desc' : 'asc'
    } else {
      sortKey.value = key
      sortDir.value = 'asc'
    }
  }

  function sortIcon(key: K): 'up' | 'down' | 'none' {
    if (sortKey.value !== key) return 'none'
    return sortDir.value === 'asc' ? 'up' : 'down'
  }

  return { sortKey: sortKey as Ref<K>, sortDir, toggleSort, sortIcon }
}
