<script setup lang="ts">
import { IconTrash } from '@tabler/icons-vue'

const props = defineProps<{
  disabled?: boolean
}>()

const emit = defineEmits<{
  delete: []
}>()

const THRESHOLD = 80
const MAX_SWIPE = 100
const RESISTANCE = 0.5

const swiping = ref(false)
const offsetX = ref(0)
const startX = ref(0)
const startY = ref(0)
const locked = ref(false) // locks direction once determined

function onTouchStart(e: TouchEvent) {
  if (props.disabled) return
  startX.value = e.touches[0].clientX
  startY.value = e.touches[0].clientY
  locked.value = false
}

function onTouchMove(e: TouchEvent) {
  if (props.disabled) return

  const dx = startX.value - e.touches[0].clientX
  const dy = e.touches[0].clientY - startY.value

  // Determine direction on first significant movement
  if (!locked.value && (Math.abs(dx) > 5 || Math.abs(dy) > 5)) {
    // If vertical movement dominates, bail out — let page scroll
    if (Math.abs(dy) > Math.abs(dx)) {
      swiping.value = false
      return
    }
    locked.value = true
  }

  if (!locked.value) return

  // Only swipe left (dx > 0)
  if (dx <= 0) {
    offsetX.value = 0
    swiping.value = false
    return
  }

  e.preventDefault()
  swiping.value = true
  offsetX.value = Math.min(dx * RESISTANCE, MAX_SWIPE)
}

function onTouchEnd() {
  if (!swiping.value) {
    offsetX.value = 0
    return
  }

  if (offsetX.value >= THRESHOLD * RESISTANCE) {
    // Snap open to reveal delete button
    offsetX.value = MAX_SWIPE
    swiping.value = false
  } else {
    // Snap back
    offsetX.value = 0
    swiping.value = false
  }
}

function close() {
  offsetX.value = 0
  swiping.value = false
}

function onDelete() {
  emit('delete')
  close()
}

// Close when clicking elsewhere
onMounted(() => {
  document.addEventListener('touchstart', handleOutsideTouch)
})
onUnmounted(() => {
  document.removeEventListener('touchstart', handleOutsideTouch)
})

const containerRef = ref<HTMLElement | null>(null)
function handleOutsideTouch(e: TouchEvent) {
  if (offsetX.value > 0 && containerRef.value && !containerRef.value.contains(e.target as Node)) {
    close()
  }
}
</script>

<template>
  <div ref="containerRef" class="relative overflow-hidden" @touchstart.passive="onTouchStart" @touchmove="onTouchMove" @touchend.passive="onTouchEnd">
    <!-- Delete button behind -->
    <div
      class="absolute inset-y-0 right-0 flex items-center justify-center bg-destructive text-destructive-foreground transition-opacity"
      :class="offsetX > 0 ? 'opacity-100' : 'opacity-0'"
      :style="{ width: `${MAX_SWIPE}px` }"
    >
      <button class="flex h-full w-full flex-col items-center justify-center gap-1 text-xs font-medium" @click="onDelete">
        <IconTrash class="size-5" />
      </button>
    </div>

    <!-- Swipeable content -->
    <div
      :style="{
        transform: `translateX(${-offsetX}px)`,
        transition: swiping ? 'none' : 'transform 0.25s ease-out',
      }"
    >
      <slot />
    </div>
  </div>
</template>
