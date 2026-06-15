import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { ref } from 'vue'

// PurchasePricesSection imports `usePurchasePrices` explicitly, so mock the
// module (stubGlobal wouldn't intercept an explicit import). The real composable
// calls Nuxt auto-imports (useState/useSupabaseClient) that don't exist here.
const { addPurchasePrice } = vi.hoisted(() => ({ addPurchasePrice: vi.fn(async () => ({})) }))
vi.mock('~/composables/usePurchasePrices', () => ({
  usePurchasePrices: () => ({
    suppliers: [],
    fetchSuppliers: vi.fn(async () => {}),
    fetchPurchasePrices: vi.fn(async () => []),
    resolveTaxRate: vi.fn(async () => null),
    addPurchasePrice,
    updatePurchasePrice: vi.fn(async () => ({})),
    deletePurchasePrice: vi.fn(async () => {}),
  }),
}))

// `useI18n` is a bare Nuxt auto-import in the SFCs — expose it as a global.
vi.stubGlobal('useI18n', () => ({
  t: (key: string, params?: Record<string, unknown>) => (params?.name ? `${key}:${params.name}` : key),
  locale: ref('de'),
}))

import PurchasePricesSection from '../PurchasePricesSection.vue'
import SupplierCombobox from '../SupplierCombobox.vue'

function mountCreate() {
  return mount(PurchasePricesSection, {
    props: { productId: null, sellprice: 1.2, pending: [] },
    // `<SupplierCombobox>` / `<FormError>` are Nuxt auto-imports in the SFC;
    // register the real combobox so findComponent works, stub FormError.
    global: { components: { SupplierCombobox }, stubs: { FormError: true } },
  })
}

describe('PurchasePricesSection — create (buffer) mode', () => {
  beforeEach(() => { addPurchasePrice.mockClear() })

  it('buffers an entry (emits update:pending) and does NOT call the add RPC when productId is null', async () => {
    const wrapper = mountCreate()
    await flushPromises()

    // Choose/create a supplier via the child combobox v-model
    wrapper.findComponent(SupplierCombobox).vm.$emit('update:modelValue', 'Metro')
    // Enter a unit price
    await wrapper.find('input[type="number"]').setValue('0.5')
    // Click "add"
    await wrapper.find('[data-testid="ek-submit"]').trigger('click')
    await flushPromises()

    const emitted = wrapper.emitted('update:pending')
    expect(emitted, 'should emit a buffered pending list').toBeTruthy()
    const lastCall = emitted![emitted!.length - 1]!
    const last = lastCall[0] as Array<Record<string, unknown>>
    expect(last).toHaveLength(1)
    expect(last[0]).toMatchObject({ supplierName: 'Metro', price: 0.5, basis: 'net' })

    // Create mode must NOT persist via the RPC — the parent flushes after create.
    expect(addPurchasePrice).not.toHaveBeenCalled()
  })

  it('requires a supplier + price before buffering', async () => {
    const wrapper = mountCreate()
    await flushPromises()
    await wrapper.find('[data-testid="ek-submit"]').trigger('click')
    await flushPromises()
    expect(wrapper.emitted('update:pending')).toBeFalsy()
  })
})
