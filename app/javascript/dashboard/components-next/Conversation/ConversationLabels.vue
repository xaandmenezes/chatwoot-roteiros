<script setup>
import { computed, nextTick, ref, useId, watch } from 'vue';
import { useResizeObserver } from '@vueuse/core';
import { useMapGetter } from 'dashboard/composables/store';
import Label from 'dashboard/components-next/label/Label.vue';
import Popover from 'dashboard/components-next/popover/Popover.vue';

const props = defineProps({
  conversationLabels: { type: Array, default: () => [] },
  contactLabels: { type: Array, default: () => [] },
  alignEnd: { type: Boolean, default: false },
});

const accountLabels = useMapGetter('labels/getLabels');
const labelRow = ref(null);
const overflowButton = ref(null);
const overflowContent = ref(null);
const visibleCount = ref(null);
const overflowId = useId();

const activeLabels = computed(() => {
  const conversationTitles = new Set(props.conversationLabels);
  const contactTitles = new Set(props.contactLabels);
  const conversationLabels = accountLabels.value.filter(label =>
    conversationTitles.has(label.title)
  );
  const contactLabels = accountLabels.value.filter(
    label =>
      contactTitles.has(label.title) && !conversationTitles.has(label.title)
  );
  return [...conversationLabels, ...contactLabels];
});

const overflowLabels = computed(() =>
  activeLabels.value.slice(visibleCount.value ?? activeLabels.value.length)
);

const overflowCountText = computed(() => `+${overflowLabels.value.length}`);

const GAP = 6; // gap-1.5
const OVERFLOW_BUTTON_WIDTH = 48; // w-12

const fitLabels = () => {
  const row = labelRow.value;
  if (!row) return;

  const labels = Array.from(row.querySelectorAll('[data-conversation-label]'));
  const labelWidths = labels.map(label => label.offsetWidth + GAP);
  const availableWidth = row.clientWidth;
  const fullWidth = labelWidths.reduce((sum, width) => sum + width, 0) - GAP;
  if (fullWidth <= availableWidth) {
    visibleCount.value = labels.length;
    return;
  }

  let remaining = availableWidth - OVERFLOW_BUTTON_WIDTH;
  const firstOverflowIndex = labelWidths.findIndex(width => {
    remaining -= width;
    return remaining < 0;
  });
  visibleCount.value =
    firstOverflowIndex === -1 ? labels.length : firstOverflowIndex;
};

useResizeObserver(labelRow, fitLabels);
watch([activeLabels, labelRow], fitLabels, { flush: 'post' });

const focusOverflow = async () => {
  await nextTick();
  overflowContent.value?.focus({ preventScroll: true });
};

const restoreFocus = () => {
  if (document.activeElement === overflowContent.value) {
    overflowButton.value?.focus({ preventScroll: true });
  }
};
</script>

<template>
  <div
    v-show="activeLabels.length || $slots.before"
    class="flex min-w-0 items-center gap-1.5"
  >
    <div v-if="$slots.before" class="shrink-0">
      <slot name="before" />
    </div>
    <div
      ref="labelRow"
      class="relative flex min-w-0 flex-1 items-center gap-1.5 overflow-hidden empty:hidden"
      :class="{ 'justify-end': alignEnd }"
    >
      <Label
        v-for="(label, index) in activeLabels"
        :key="label.id"
        :label="label"
        data-conversation-label
        compact
        :class="{
          'invisible absolute': visibleCount !== null && index >= visibleCount,
        }"
      />
      <div v-if="overflowLabels.length" class="flex shrink-0" @click.stop>
        <Popover @show="focusOverflow" @hide="restoreFocus">
          <template #default="{ isOpen }">
            <button
              ref="overflowButton"
              type="button"
              class="h-6 w-12 rounded-md bg-n-button-color text-xs text-n-slate-12 focus-visible:outline focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-n-blue-9"
              :aria-label="`+${overflowLabels.length} ${$t('CONVERSATION.CARD.SHOW_LABELS')}`"
              :aria-controls="isOpen ? overflowId : undefined"
              :aria-expanded="isOpen"
            >
              {{ overflowCountText }}
            </button>
          </template>
          <template #content>
            <div
              :id="overflowId"
              ref="overflowContent"
              role="region"
              tabindex="-1"
              :aria-label="$t('CONVERSATION.CARD.SHOW_LABELS')"
              class="flex max-w-[min(24rem,calc(100vw-2rem))] flex-wrap gap-1.5 p-2"
            >
              <Label
                v-for="label in overflowLabels"
                :key="label.id"
                :label="label"
                compact
                class="!h-auto min-h-6 max-w-full [&>span:last-child]:whitespace-normal [&>span:last-child]:[overflow-wrap:anywhere]"
              />
            </div>
          </template>
        </Popover>
      </div>
    </div>
  </div>
</template>
