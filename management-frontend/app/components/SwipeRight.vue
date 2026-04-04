<script setup lang="ts">
/**
 * Swipe-right reveal component for mobile actions.
 * Wraps content and reveals an action button on the LEFT when swiping right.
 * Mirrors the SwipeToDelete pattern but in the opposite direction.
 */
const props = defineProps<{
  disabled?: boolean
  label?: string
}>()

const emit = defineEmits<{
  action: []
}>()

const THRESHOLD = 80
const MAX_SWIPE = 100
const RESISTANCE = 0.5

const swiping = ref(false)
const offsetX = ref(0)
const startX = ref(0)
const startY = ref(0)
const locked = ref(false)

function onTouchStart(e: TouchEvent) {
  if (props.disabled) return
  startX.value = e.touches[0].clientX
  startY.value = e.touches[0].clientY
  locked.value = false
}

function onTouchMove(e: TouchEvent) {
  if (props.disabled) return

  const dx = e.touches[0].clientX - startX.value // positive = swipe right
  const dy = e.touches[0].clientY - startY.value

  if (!locked.value && (Math.abs(dx) > 5 || Math.abs(dy) > 5)) {
    if (Math.abs(dy) > Math.abs(dx)) {
      swiping.value = false
      return
    }
    locked.value = true
  }

  if (!locked.value) return

  // Only swipe right (dx > 0)
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
    offsetX.value = MAX_SWIPE
    swiping.value = false
  } else {
    offsetX.value = 0
    swiping.value = false
  }
}

function close() {
  offsetX.value = 0
  swiping.value = false
}

function onAction() {
  emit('action')
  close()
}

const containerRef = ref<HTMLElement | null>(null)
function handleOutsideTouch(e: TouchEvent) {
  if (offsetX.value > 0 && containerRef.value && !containerRef.value.contains(e.target as Node)) {
    close()
  }
}

onMounted(() => {
  document.addEventListener('touchstart', handleOutsideTouch)
})
onUnmounted(() => {
  document.removeEventListener('touchstart', handleOutsideTouch)
})
</script>

<template>
  <div ref="containerRef" class="relative overflow-hidden rounded-lg" @touchstart.passive="onTouchStart" @touchmove="onTouchMove" @touchend.passive="onTouchEnd">
    <!-- Action button revealed on the LEFT -->
    <div
      class="absolute inset-y-0 left-0 flex items-center justify-center bg-primary text-primary-foreground transition-opacity"
      :class="offsetX > 0 ? 'opacity-100' : 'opacity-0'"
      :style="{ width: `${MAX_SWIPE}px` }"
    >
      <button class="flex h-full w-full flex-col items-center justify-center gap-1 text-xs font-medium" @click="onAction">
        <slot name="icon" />
        <span v-if="label">{{ label }}</span>
      </button>
    </div>

    <!-- Swipeable content -->
    <div
      :style="{
        transform: `translateX(${offsetX}px)`,
        transition: swiping ? 'none' : 'transform 0.25s ease-out',
      }"
    >
      <slot />
    </div>
  </div>
</template>
