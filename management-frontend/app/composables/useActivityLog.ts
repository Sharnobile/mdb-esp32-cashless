export interface ActivityLogEntry {
    id: string
    created_at: string
    company_id: string
    user_id: string | null
    entity_type: string
    entity_id: string | null
    action: string
    metadata: Record<string, unknown> | null
    // Enriched client-side
    user_display?: string
}

// Cache user labels to avoid re-fetching on paginate
const userCache = new Map<string, string>()

export function useActivityLog() {
    const supabase = useSupabaseClient()

    const logs = ref<ActivityLogEntry[]>([])
    const loading = ref(false)
    const hasMore = ref(true)

    // Filters
    const entityTypeFilter = ref<string>('')
    const dateFrom = ref<string>('')
    const dateTo = ref<string>('')
    const searchQuery = ref<string>('')

    const PAGE_SIZE = 50

    // ── Enrich entries with human-readable user names ────────────────────────
    async function enrichWithUsers(entries: ActivityLogEntry[]): Promise<ActivityLogEntry[]> {
        // First pass: entries that already have _user_display baked into metadata
        // (written by the frontend composable) are resolved immediately — no DB needed.
        const needsLookup = entries.filter(e => {
            if (!e.user_id) return false // System — no lookup needed
            const baked = (e.metadata as any)?._user_display
            return !baked // only look up entries without baked-in name
        })

        if (needsLookup.length > 0) {
            const unknownIds = [...new Set(
                needsLookup.map(e => e.user_id).filter((id): id is string => !!id && !userCache.has(id))
            )]

            if (unknownIds.length > 0) {
                const { data: users } = await (supabase as any)
                    .from('users')
                    .select('id, email, first_name, last_name')
                    .in('id', unknownIds)

                for (const u of users ?? []) {
                    const name = [u.first_name, u.last_name].filter(Boolean).join(' ').trim()
                    userCache.set(u.id, name || u.email || u.id.slice(0, 8))
                }
            }
        }

        return entries.map(e => {
            let display: string
            if (!e.user_id) {
                display = 'System'
            } else {
                // Prefer the display name baked into metadata at write time
                const baked = (e.metadata as any)?._user_display as string | undefined
                display = baked || userCache.get(e.user_id) || (e.metadata as any)?._user_email || e.user_id.slice(0, 8)
            }
            return { ...e, user_display: display }
        })
    }

    // ── Build the base query with current filters ────────────────────────────
    function buildQuery() {
        let q = (supabase as any)
            .from('activity_log')
            .select('*')
            .order('created_at', { ascending: false })

        if (entityTypeFilter.value) {
            q = q.eq('entity_type', entityTypeFilter.value)
        }
        if (dateFrom.value) {
            q = q.gte('created_at', dateFrom.value)
        }
        if (dateTo.value) {
            // Add one day so "to" is inclusive
            const nextDay = new Date(dateTo.value)
            nextDay.setDate(nextDay.getDate() + 1)
            q = q.lt('created_at', nextDay.toISOString().split('T')[0])
        }
        return q
    }

    // ── Initial / filtered fetch ─────────────────────────────────────────────
    async function fetchLogs() {
        loading.value = true
        hasMore.value = true
        try {
            const { data, error } = await buildQuery().limit(PAGE_SIZE)
            if (error) throw error
            logs.value = await enrichWithUsers((data ?? []) as ActivityLogEntry[])
            hasMore.value = logs.value.length === PAGE_SIZE
        } finally {
            loading.value = false
        }
    }

    // ── Load more (pagination) ───────────────────────────────────────────────
    async function fetchMore() {
        if (!hasMore.value || loading.value) return
        loading.value = true
        try {
            const oldest = logs.value[logs.value.length - 1]?.created_at
            const { data, error } = await buildQuery()
                .lt('created_at', oldest)
                .limit(PAGE_SIZE)
            if (error) throw error
            const next = await enrichWithUsers((data ?? []) as ActivityLogEntry[])
            logs.value.push(...next)
            hasMore.value = next.length === PAGE_SIZE
        } finally {
            loading.value = false
        }
    }

    // ── Realtime: prepend new entries ────────────────────────────────────────
    function subscribe() {
        const channel = (supabase as any)
            .channel('activity_log_realtime')
            .on(
                'postgres_changes',
                { event: 'INSERT', schema: 'public', table: 'activity_log' },
                async (payload: { new: ActivityLogEntry }) => {
                    const entry = payload.new
                    if (entityTypeFilter.value && entry.entity_type !== entityTypeFilter.value) return
                    if (dateFrom.value && entry.created_at < dateFrom.value) return
                    const [enriched] = await enrichWithUsers([entry])
                    logs.value.unshift(enriched!)
                },
            )
            .subscribe()

        return () => supabase.removeChannel(channel)
    }

    // ── Icon / colour per entity type ───────────────────────────────────────
    // Action labels + detail chips now live in `useActivityDescriptor` so the
    // history page and dashboard feed render every action type identically.
    function entityTypeVariant(type: string): 'default' | 'secondary' | 'destructive' | 'outline' {
        const map: Record<string, 'default' | 'secondary' | 'destructive' | 'outline'> = {
            sale: 'default',
            credit: 'secondary',
            stock: 'outline',
            firmware: 'destructive',
            device: 'secondary',
            cash_book: 'secondary',
        }
        return map[type] ?? 'outline'
    }

    // ── Client-side search across metadata fields ─────────────────────────
    const filteredLogs = computed(() => {
        const q = searchQuery.value.trim().toLowerCase()
        if (!q) return logs.value
        return logs.value.filter(entry => {
            const m = entry.metadata
            if (!m) return false
            // Search across common metadata string fields
            const searchable = [
                m.machine_name, m.product_name, m.channel,
                m.device_id, entry.user_display,
            ].filter(Boolean).map(v => String(v).toLowerCase())
            return searchable.some(s => s.includes(q))
        })
    })

    return {
        logs: filteredLogs,
        rawLogs: logs,
        loading,
        hasMore,
        entityTypeFilter,
        dateFrom,
        dateTo,
        searchQuery,
        fetchLogs,
        fetchMore,
        subscribe,
        entityTypeVariant,
    }
}
