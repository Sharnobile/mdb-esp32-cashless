<script setup lang="ts">
import {
  IconBuildingWarehouse,
  IconCpu,
  IconDashboard,
  IconFileSpreadsheet,
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

const navGroups = computed(() => {
  const groups = [
    {
      items: [
        {
          title: t('nav.dashboard'),
          url: "/",
          icon: IconDashboard,
        },
      ],
    },
    {
      label: t('nav.groupOperations'),
      items: [
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
          title: t('nav.reports'),
          url: "/reports",
          icon: IconFileSpreadsheet,
        },
      ],
    },
    {
      label: t('nav.groupTeam'),
      items: [
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
      ],
    },
  ]

  if (role.value === 'admin') {
    groups.push({
      label: t('nav.groupTechnical'),
      items: [
        {
          title: t('nav.devices'),
          url: "/devices",
          icon: IconCpu,
        },
        {
          title: t('nav.firmware'),
          url: "/firmware",
          icon: IconCloudUpload,
        },
        {
          title: t('nav.apiKeys'),
          url: "/api-keys",
          icon: IconKey,
        },
      ],
    })
  }

  return groups
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
      <NavMain :groups="navGroups" />
      <NavSecondary :items="navSecondary" class="mt-auto" />
    </SidebarContent>
    <SidebarFooter>
      <NavUser />
    </SidebarFooter>
  </Sidebar>
</template>
