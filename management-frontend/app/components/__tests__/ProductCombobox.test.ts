import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { ref } from 'vue'

// ProductCombobox uses the Nuxt auto-import `useI18n()`. The vitest setup only
// stubs `#imports`, not template-level auto-imports, so expose it as a global.
vi.stubGlobal('useI18n', () => ({
  t: (key: string, params?: Record<string, unknown>) =>
    params?.name ? `${key}:${params.name}` : key,
  locale: ref('de'),
}))

import ProductCombobox from '../ProductCombobox.vue'

const PRODUCTS = [
  { id: '1', name: 'Mars' },
  { id: '2', name: 'Snickers' },
]

async function openAndType(text: string, props: Record<string, unknown> = {}) {
  const wrapper = mount(ProductCombobox, {
    attachTo: document.body,
    props: { modelValue: null, products: PRODUCTS, placeholder: 'Produkt', allowCreate: true, ...props },
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

describe('ProductCombobox', () => {
  beforeEach(() => { document.body.innerHTML = '' })

  it('offers to create a product when typing a new name, and emits the TYPED name on click', async () => {
    const wrapper = await openAndType('Neues Produkt XYZ')

    // reka-ui's CommandItem filters by mount-time textContent, so the create
    // action must be a plain button (data-testid) that survives a growing query.
    const createBtn = document.body.querySelector('[data-testid="create-product"]') as HTMLElement | null
    expect(createBtn, 'a create-product action should appear for a new, non-matching name').not.toBeNull()

    createBtn!.click()
    await flushPromises()

    // The whole point: the consumer pre-fills its "new product" modal from this
    // string, so it MUST be the typed name — not an empty string.
    expect(wrapper.emitted('create')?.[0]).toEqual(['Neues Produkt XYZ'])
  })

  it('does NOT offer create when the typed name exactly matches an existing product', async () => {
    await openAndType('Mars')
    const createBtn = document.body.querySelector('[data-testid="create-product"]')
    expect(createBtn).toBeNull()
  })

  it('does NOT offer create when allowCreate is false', async () => {
    await openAndType('Neues Produkt XYZ', { allowCreate: false })
    const createBtn = document.body.querySelector('[data-testid="create-product"]')
    expect(createBtn).toBeNull()
  })
})
