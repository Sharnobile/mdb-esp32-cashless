import { ref, type Ref } from 'vue'

export function useModalForm<T extends Record<string, unknown>>(defaults: T) {
  const open = ref(false)
  const form = ref<T>({ ...defaults }) as Ref<T>
  const loading = ref(false)
  const error = ref('')

  function openModal(initial?: Partial<T>) {
    form.value = { ...defaults, ...initial } as T
    error.value = ''
    loading.value = false
    open.value = true
  }

  function closeModal() {
    open.value = false
  }

  async function submit(fn: () => Promise<void>, opts?: { closeOnSuccess?: boolean }) {
    loading.value = true
    error.value = ''
    try {
      await fn()
      if (opts?.closeOnSuccess !== false) closeModal()
    } catch (err: unknown) {
      error.value = err instanceof Error ? err.message : String(err)
    } finally {
      loading.value = false
    }
  }

  return { open, form, loading, error, openModal, closeModal, submit }
}
