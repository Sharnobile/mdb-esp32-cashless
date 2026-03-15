import { useSupabaseClient } from '#imports'

interface Organization {
  id: string
  name: string
  created_at: string
}

export type OrgFetchError = 'server' | 'auth' | null

export function useOrganization() {
  const organization = useState<Organization | null>('organization', () => null)
  const role = useState<string | null>('org-role', () => null)
  const loading = ref(false)
  const fetchError = useState<OrgFetchError>('org-fetch-error', () => null)

  async function fetchOrganization() {
    loading.value = true
    fetchError.value = null
    try {
      const supabase = useSupabaseClient()
      const { data, error } = await supabase.functions.invoke('get-my-organization')

      if (error) {
        // Supabase functions-js error types:
        // - FunctionsHttpError: non-2xx response, context = Response object
        // - FunctionsFetchError: network failure (server down, DNS, etc.)
        // - FunctionsRelayError: relay can't reach function
        const errorName = error?.name ?? ''
        if (errorName === 'FunctionsFetchError' || errorName === 'FunctionsRelayError') {
          fetchError.value = 'server'
        } else if (errorName === 'FunctionsHttpError') {
          const status = error?.context?.status ?? 0
          // 502, 503, 504 = server not ready; 500 = edge function crash
          fetchError.value = status >= 500 ? 'server' : 'auth'
        } else {
          fetchError.value = 'server'
        }
        throw error
      }

      organization.value = data.organization ?? null
      role.value = data.role ?? null
    } catch (err) {
      if (!fetchError.value) {
        fetchError.value = 'server'
      }
      throw err
    } finally {
      loading.value = false
    }
  }

  return { organization, role, loading, fetchError, fetchOrganization }
}
