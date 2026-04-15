<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { useProductDetail } from '~/composables/useProductDetail'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { IconArrowLeft, IconPencil } from '@tabler/icons-vue'

const { t } = useI18n()
const route = useRoute()
const router = useRouter()

const productId = computed(() => route.params.id as string)
const detail = useProductDetail(productId)

const editModalOpen = ref(false)

onMounted(() => detail.refresh())
watch(productId, () => detail.refresh())

function goBack() {
  if (window.history.length > 1) router.back()
  else router.push('/products')
}

function onEditSaved() {
  editModalOpen.value = false
  detail.refresh()
}
</script>

<template>
  <div class="container mx-auto max-w-6xl px-4 py-6 space-y-6">
    <!-- Header -->
    <div class="flex items-start gap-3">
      <Button variant="ghost" size="icon" @click="goBack">
        <IconArrowLeft class="size-5" />
      </Button>

      <template v-if="detail.loading.value && !detail.product.value">
        <div class="h-16 flex-1 animate-pulse rounded-md bg-muted" />
      </template>

      <template v-else-if="detail.notFound.value">
        <div class="flex-1 rounded-md border border-destructive/20 bg-destructive/5 p-4">
          <p class="font-medium">{{ t('products.detail.notFound.title') }}</p>
          <NuxtLink to="/products" class="mt-1 inline-block text-sm underline">
            {{ t('products.detail.notFound.back') }}
          </NuxtLink>
        </div>
      </template>

      <template v-else-if="detail.product.value">
        <img
          v-if="detail.product.value.image_url"
          :src="detail.product.value.image_url"
          :alt="detail.product.value.name"
          class="size-16 rounded-md object-cover border"
        />
        <div v-else class="size-16 rounded-md border bg-muted" />

        <div class="flex-1">
          <div class="flex items-center gap-2">
            <h1 class="text-2xl font-semibold">{{ detail.product.value.name }}</h1>
            <Badge v-if="detail.product.value.discontinued" variant="secondary">
              {{ t('products.detail.header.discontinued') }}
            </Badge>
          </div>
          <p v-if="detail.product.value.category_name" class="text-sm text-muted-foreground">
            {{ detail.product.value.category_name }}
          </p>
          <div v-if="detail.barcodes.value.length" class="mt-1 flex flex-wrap gap-1">
            <span
              v-for="b in detail.barcodes.value"
              :key="b.id"
              class="rounded-full border bg-muted/50 px-2 py-0.5 text-xs font-mono"
            >
              {{ b.barcode }}
            </span>
          </div>
        </div>

        <Button variant="outline" @click="editModalOpen = true">
          <IconPencil class="mr-2 size-4" />
          {{ t('products.detail.header.edit') }}
        </Button>
      </template>
    </div>

    <!-- Sections will be added in Chunk 2 -->
    <div v-if="detail.product.value" class="rounded-md border border-dashed p-8 text-center text-sm text-muted-foreground">
      Sections coming in the next chunk.
    </div>

    <ProductFormModal
      v-model:open="editModalOpen"
      :product-id="productId"
      @saved="onEditSaved"
    />
  </div>
</template>
