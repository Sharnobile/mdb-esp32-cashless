<script setup lang="ts">
import type { Component } from "vue"

import {
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  useSidebar,
} from '@/components/ui/sidebar'

interface NavItem {
  title: string
  url: string
  icon?: Component
}

export interface NavGroup {
  label?: string
  items: NavItem[]
}

defineProps<{
  groups: NavGroup[]
}>()

const { isMobile, setOpenMobile } = useSidebar()

function handleNavClick() {
  if (isMobile.value) {
    setOpenMobile(false)
  }
}
</script>

<template>
  <SidebarGroup v-for="(group, index) in groups" :key="index">
    <SidebarGroupLabel v-if="group.label">{{ group.label }}</SidebarGroupLabel>
    <SidebarGroupContent>
      <SidebarMenu>
        <SidebarMenuItem v-for="item in group.items" :key="item.title">
          <SidebarMenuButton as-child :tooltip="item.title">
            <NuxtLink :to="item.url" @click="handleNavClick">
              <component :is="item.icon" v-if="item.icon" />
              <span>{{ item.title }}</span>
            </NuxtLink>
          </SidebarMenuButton>
        </SidebarMenuItem>
      </SidebarMenu>
    </SidebarGroupContent>
  </SidebarGroup>
</template>
