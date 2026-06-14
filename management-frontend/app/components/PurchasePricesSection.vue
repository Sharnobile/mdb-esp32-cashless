<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { formatCurrency } from '@/lib/utils'
import { usePurchasePrices, type PurchasePrice } from '~/composables/usePurchasePrices'
import { counterpart, marginNet } from '~/lib/purchaseComparison'

const props = defineProps<{ productId: string; sellprice: number | null }>()
const { t, locale } = useI18n()
const { suppliers, fetchSuppliers, fetchPurchasePrices, resolveTaxRate, addPurchasePrice, updatePurchasePrice, deletePurchasePrice } = usePurchasePrices()

const prices = ref<PurchasePrice[]>([])
const loading = ref(false)
const error = ref('')
const resolvedRate = ref<number | null>(null)

const today = () => new Date().toISOString().slice(0, 10)
const form = ref({ supplierName: '', price: null as number | null, basis: 'net' as 'net' | 'gross', observedOn: today(), note: '', taxRatePct: null as number | null })
const editingId = ref<string | null>(null)

const needRateOverride = computed(() => resolvedRate.value == null)
const effectiveRate = computed<number | null>(() =>
  needRateOverride.value ? (form.value.taxRatePct == null ? null : form.value.taxRatePct / 100) : resolvedRate.value,
)
const counterpartText = computed(() => {
  if (form.value.price == null || effectiveRate.value == null) return ''
  const other = counterpart(form.value.price, form.value.basis, effectiveRate.value)
  const label = form.value.basis === 'net' ? t('purchasePrices.gross') : t('purchasePrices.net')
  return `= ${formatCurrency(other, locale.value)} ${label}`
})

const newest = computed(() => prices.value[0] ?? null) // already sorted observed_on desc
const cheapestId = computed(() => {
  if (prices.value.length === 0) return null
  return [...prices.value].sort((a, b) => a.price_gross - b.price_gross)[0]!.id
})
const margin = computed(() =>
  newest.value ? marginNet(props.sellprice, newest.value.price_net, newest.value.tax_rate) : null,
)

async function reload() {
  loading.value = true
  try {
    prices.value = await fetchPurchasePrices(props.productId)
    resolvedRate.value = await resolveTaxRate(props.productId)
  } finally {
    loading.value = false
  }
}

watch(() => props.productId, async () => {
  await Promise.all([fetchSuppliers(), reload()])
  resetForm()
}, { immediate: true })

function resetForm() {
  form.value = { supplierName: '', price: null, basis: 'net', observedOn: today(), note: '', taxRatePct: null }
  editingId.value = null
  error.value = ''
}

function startEdit(p: PurchasePrice) {
  editingId.value = p.id
  form.value = {
    supplierName: p.supplier_name,
    price: p.price_basis === 'net' ? p.price_net : p.price_gross,
    basis: p.price_basis,
    observedOn: p.observed_on,
    note: p.note ?? '',
    taxRatePct: needRateOverride.value ? Number((p.tax_rate * 100).toFixed(2)) : null,
  }
}

async function submit() {
  if (!form.value.supplierName.trim() || form.value.price == null) {
    error.value = t('purchasePrices.supplierAndPriceRequired')
    return
  }
  if (needRateOverride.value && form.value.taxRatePct == null) {
    error.value = t('purchasePrices.taxRateRequired')
    return
  }
  error.value = ''
  const input = {
    productId: props.productId,
    supplierName: form.value.supplierName.trim(),
    price: form.value.price,
    basis: form.value.basis,
    observedOn: form.value.observedOn,
    note: form.value.note.trim() || null,
    taxRateOverride: needRateOverride.value && form.value.taxRatePct != null ? form.value.taxRatePct / 100 : null,
  }
  try {
    if (editingId.value) await updatePurchasePrice(editingId.value, input)
    else await addPurchasePrice(input)
    await reload()
    resetForm()
  } catch (e: any) {
    error.value = e?.message ?? t('purchasePrices.saveFailed')
  }
}

async function remove(id: string) {
  await deletePurchasePrice(id)
  await reload()
  if (editingId.value === id) resetForm()
}
</script>

<template>
  <details class="rounded-md border">
    <summary class="cursor-pointer select-none px-3 py-2 text-sm font-medium">
      {{ t('purchasePrices.title') }} <span class="text-muted-foreground">({{ prices.length }})</span>
    </summary>
    <div class="space-y-3 border-t p-3">
      <!-- History -->
      <div v-if="prices.length" class="space-y-1">
        <div
          v-for="p in prices"
          :key="p.id"
          class="flex items-center gap-2 rounded-md border px-2 py-1 text-xs"
        >
          <span class="w-4 shrink-0">{{ p.id === cheapestId ? '★' : '' }}</span>
          <span class="flex-1 truncate font-medium">
            {{ p.supplier_name }}
            <span v-if="p.id === newest?.id" class="ml-1 text-[10px] text-muted-foreground">{{ t('purchasePrices.usual') }}</span>
          </span>
          <span>{{ formatCurrency(p.price_net, locale) }} {{ t('purchasePrices.net') }}</span>
          <span class="text-muted-foreground">{{ formatCurrency(p.price_gross, locale) }} {{ t('purchasePrices.gross') }}</span>
          <span class="text-muted-foreground">{{ p.observed_on }}</span>
          <button type="button" class="text-primary hover:underline" @click="startEdit(p)">{{ t('common.edit') }}</button>
          <button type="button" class="text-destructive hover:underline" @click="remove(p.id)">{{ t('common.delete') }}</button>
        </div>
      </div>
      <p v-else class="text-xs text-muted-foreground">{{ t('purchasePrices.noPrices') }}</p>

      <!-- Add / edit form -->
      <div class="grid grid-cols-2 gap-2">
        <div class="col-span-2">
          <label class="text-xs text-muted-foreground">{{ t('purchasePrices.supplier') }}</label>
          <SupplierCombobox v-model="form.supplierName" :suppliers="suppliers" :placeholder="t('purchasePrices.supplierPlaceholder')" />
        </div>
        <div>
          <label class="text-xs text-muted-foreground">{{ t('purchasePrices.pricePerUnit') }}</label>
          <input v-model.number="form.price" type="number" step="0.0001" min="0" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm" />
        </div>
        <div>
          <label class="text-xs text-muted-foreground">{{ t('purchasePrices.basis') }}</label>
          <div class="flex h-9 items-center gap-1">
            <button type="button" :class="['flex-1 rounded-md border text-xs h-9', form.basis === 'net' ? 'bg-primary text-primary-foreground' : '']" @click="form.basis = 'net'">{{ t('purchasePrices.net') }}</button>
            <button type="button" :class="['flex-1 rounded-md border text-xs h-9', form.basis === 'gross' ? 'bg-primary text-primary-foreground' : '']" @click="form.basis = 'gross'">{{ t('purchasePrices.gross') }}</button>
          </div>
        </div>
        <p v-if="counterpartText" class="col-span-2 text-xs text-muted-foreground">{{ counterpartText }}</p>
        <div v-if="needRateOverride" class="col-span-2">
          <label class="text-xs text-amber-600">{{ t('purchasePrices.taxRateField') }}</label>
          <input v-model.number="form.taxRatePct" type="number" step="0.1" min="0" placeholder="19" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm" />
        </div>
        <div>
          <label class="text-xs text-muted-foreground">{{ t('purchasePrices.date') }}</label>
          <input v-model="form.observedOn" type="date" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm" />
        </div>
        <div>
          <label class="text-xs text-muted-foreground">{{ t('purchasePrices.note') }}</label>
          <input v-model="form.note" type="text" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm" />
        </div>
      </div>
      <FormError :message="error" />
      <div class="flex gap-2">
        <button v-if="editingId" type="button" class="h-8 flex-1 rounded-md border text-xs" @click="resetForm">{{ t('common.cancel') }}</button>
        <button type="button" class="h-8 flex-1 rounded-md bg-primary text-xs text-primary-foreground" @click="submit">
          {{ editingId ? t('common.save') : t('common.add') }}
        </button>
      </div>

      <!-- Margin -->
      <p v-if="margin" class="text-xs">
        <strong>{{ t('purchasePrices.margin') }}:</strong>
        {{ formatCurrency(margin.rohertrag, locale) }} · {{ margin.spannePct.toFixed(0) }}%
        <span class="text-muted-foreground">({{ t('purchasePrices.marginHint') }})</span>
      </p>
    </div>
  </details>
</template>
