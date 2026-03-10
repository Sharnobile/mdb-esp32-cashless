<script setup lang="ts">
import {
  IconBuildingWarehouse,
  IconCpu,
  IconDashboard,
  IconHelp,
  IconHistory,
  IconInnerShadowTop,
  IconKey,
  IconPackage,
  IconUsers,
  IconDevices,
  IconCloudUpload,
} from "@tabler/icons-vue"

import NavMain from '@/components/NavMain.vue'
import NavSecondary from '@/components/NavSecondary.vue'
import NavUser from '@/components/NavUser.vue'
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from '@/components/ui/sidebar'

const { t } = useI18n()
const { organization, role } = useOrganization()

const navMain = computed(() => {
  const items = [
    {
      title: t('nav.dashboard'),
      url: "/",
      icon: IconDashboard,
    },
    {
      title: t('nav.machines'),
      url: "/machines",
      icon: IconDevices,
    },
    {
      title: t('nav.products'),
      url: "/products",
      icon: IconPackage,
    },
    {
      title: t('nav.warehouse'),
      url: "/warehouse",
      icon: IconBuildingWarehouse,
    },
    {
      title: t('nav.members'),
      url: "/members",
      icon: IconUsers,
    },
    {
      title: t('nav.history'),
      url: "/history",
      icon: IconHistory,
    },
  ]

  if (role.value === 'admin') {
    items.push(
      {
        title: t('nav.devices'),
        url: "/devices",
        icon: IconCpu,
      },
      {
        title: t('nav.apiKeys'),
        url: "/api-keys",
        icon: IconKey,
      },
      {
        title: t('nav.firmware'),
        url: "/firmware",
        icon: IconCloudUpload,
      },
    )
  }

  return items
})

const navSecondary = computed(() => [
  {
    title: t('nav.getHelp'),
    url: "#",
    icon: IconHelp,
  },
])
</script>

<template>
  <Sidebar collapsible="offcanvas">
    <SidebarHeader>
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuButton
            as-child
            class="data-[slot=sidebar-menu-button]:!p-1.5"
          >
            <NuxtLink to="/">
              <IconInnerShadowTop class="!size-5" />
              <span class="text-base font-semibold">{{ organization?.name ?? t('nav.defaultOrg') }}</span>
            </NuxtLink>
          </SidebarMenuButton>
        </SidebarMenuItem>
      </SidebarMenu>
    </SidebarHeader>
    <SidebarContent>
      <NavMain :items="navMain" />
      <NavSecondary :items="navSecondary" class="mt-auto" />
    </SidebarContent>
    <SidebarFooter>
      <NavUser />
    </SidebarFooter>
  </Sidebar>
</template>
