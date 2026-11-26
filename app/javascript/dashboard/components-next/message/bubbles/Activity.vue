<script setup>
import { computed } from 'vue';
import { useExactTimestamp } from 'shared/composables/useExactTimestamp';
import BaseBubble from './Base.vue';
import { useMessageContext } from '../provider.js';

const { content, createdAt } = useMessageContext();
const inlineTimestamp = useExactTimestamp({ omitCurrentYear: true });

const readableTime = computed(() => inlineTimestamp(createdAt.value));
</script>

<template>
  <BaseBubble
    v-tooltip.top="readableTime"
    class="px-3 py-1 !rounded-xl flex min-w-0 items-center gap-2"
    data-bubble-name="activity"
  >
    <span :title="content">{{ content }}</span>
  </BaseBubble>
</template>
