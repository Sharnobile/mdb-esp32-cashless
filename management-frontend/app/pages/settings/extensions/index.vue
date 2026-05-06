<script setup lang="ts">
definePageMeta({ middleware: 'auth' })
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '~/components/ui/card'
import { IconShoppingBag } from '@tabler/icons-vue'

const { t } = useI18n()

const extensionPoints = [
  {
    id: 'deal-source',
    icon: IconShoppingBag,
    titleKey: 'extensions.dealSource.title',
    descKey: 'extensions.dealSource.description',
    href: '/settings/extensions/deal-source',
  },
]
</script>

<template>
  <div class="container mx-auto max-w-3xl py-6 space-y-4">
    <div>
      <h1 class="text-2xl font-semibold">{{ t('extensions.pageTitle') }}</h1>
      <p class="text-sm text-muted-foreground mt-1">{{ t('extensions.pageDescription') }}</p>
    </div>

    <div class="grid gap-3 sm:grid-cols-2">
      <NuxtLink v-for="ep in extensionPoints" :key="ep.id" :to="ep.href" class="block">
        <Card class="hover:border-primary/50 transition-colors h-full">
          <CardHeader>
            <div class="flex items-center gap-3">
              <component :is="ep.icon" class="size-5 text-primary" />
              <CardTitle>{{ t(ep.titleKey) }}</CardTitle>
            </div>
            <CardDescription>{{ t(ep.descKey) }}</CardDescription>
          </CardHeader>
        </Card>
      </NuxtLink>
    </div>
  </div>
</template>
