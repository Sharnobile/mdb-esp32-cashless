import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { ref } from 'vue'

// SupplierCombobox uses the Nuxt auto-import `useI18n()`. The vitest setup only
// stubs `#imports`, not template-level auto-imports, so expose it as a global.
vi.stubGlobal('useI18n', () => ({
  t: (key: string, params?: Record<string, unknown>) =>
    params?.name ? `${key}:${params.name}` : key,
  locale: ref('de'),
}))

import SupplierCombobox from '../SupplierCombobox.vue'

const SUPPLIERS = [
  { id: '1', name: 'Metro' },
  { id: '2', name: 'Großhandel Müller' },
]

async function openAndType(text: string) {
  const wrapper = mount(SupplierCombobox, {
    attachTo: document.body,
    props: { modelValue: '', suppliers: SUPPLIERS, placeholder: 'Lieferant' },
  })
  await wrapper.find('[role="combobox"]').trigger('click')
  await flushPromises()

  const input = document.body.querySelector('[data-slot="command-input"]') as HTMLInputElement | null
  expect(input, 'command search input should render once the popover is open').not.toBeNull()
  input!.value = text
  input!.dispatchEvent(new Event('input', { bubbles: true }))
  await flushPromises()

  return wrapper
}

describe('SupplierCombobox', () => {
  beforeEach(() => { document.body.innerHTML = '' })

  it('offers to create a supplier when typing a new name, and emits it on click', async () => {
    const wrapper = await openAndType('Neuer Lieferant')

    const createBtn = document.body.querySelector('[data-testid="create-supplier"]') as HTMLElement | null
    expect(createBtn, 'a create-supplier action should appear for a new name').not.toBeNull()

    createBtn!.click()
    await flushPromises()

    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual(['Neuer Lieferant'])
  })

  it('does NOT offer create when the typed name exactly matches an existing supplier', async () => {
    await openAndType('Metro')
    const createBtn = document.body.querySelector('[data-testid="create-supplier"]')
    expect(createBtn).toBeNull()
  })
})
