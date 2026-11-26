<script setup>
import { computed, defineAsyncComponent, shallowRef } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'vuex';
import { vOnClickOutside } from '@vueuse/components';
import { useAlert } from 'dashboard/composables';
import MessageApi from 'dashboard/api/inbox/message';
import Button from 'next/button/Button.vue';

const props = defineProps({
  messageId: { type: Number, required: true },
  conversationId: { type: Number, required: true },
  reactions: { type: Object, default: null },
  canReact: { type: Boolean, default: false },
  alignEnd: { type: Boolean, default: false },
});

const EmojiIconPicker = defineAsyncComponent(
  () => import('next/emoji-icon-picker/EmojiIconPicker.vue')
);

const { t } = useI18n();
const store = useStore();
const pickerOpen = shallowRef(false);
const sending = shallowRef(false);
const actionButton = shallowRef(null);

const visible = computed(() => {
  const fallback = {
    incoming: t('CONVERSATION.CONTEXT_MENU.REACTION.CONTACT'),
    outgoing: t('CONVERSATION.CONTEXT_MENU.REACTION.ACCOUNT'),
  };

  return Object.entries(fallback).flatMap(([direction, author]) => {
    const reaction = props.reactions?.[direction];
    if (!reaction?.emoji) return [];

    const label = t('CONVERSATION.CONTEXT_MENU.REACTION.AUTHOR', {
      emoji: reaction.emoji,
      author: reaction.author || author,
    });
    return [{ direction, emoji: reaction.emoji, label }];
  });
});

const closePicker = () => {
  pickerOpen.value = false;
};

const focusAction = () => {
  closePicker();
  actionButton.value?.$el?.focus();
};

const closeOnEscape = event => {
  if (!pickerOpen.value) return;

  event.stopPropagation();
  focusAction();
};

const react = async emoji => {
  if (sending.value || props.reactions?.pending) return;

  focusAction();
  sending.value = true;
  try {
    const { data } = await MessageApi.react(
      props.conversationId,
      props.messageId,
      emoji
    );
    store.commit('UPDATE_MESSAGE_RYZE_REACTIONS', data);
  } catch (error) {
    const message = error.response?.data?.error_code
      ? t('CONVERSATION.CONTEXT_MENU.REACTION.FAILED')
      : t('CONVERSATION.CONTEXT_MENU.REACTION.UNKNOWN');
    useAlert(message);
  } finally {
    sending.value = false;
  }
};
</script>

<template>
  <div class="flex flex-wrap items-center gap-1 empty:hidden">
    <span
      v-for="reaction in visible"
      :key="reaction.direction"
      v-tooltip.top="reaction.label"
      class="inline-flex items-center justify-center px-1.5 text-sm rounded-full min-h-5 bg-n-surface-2 outline outline-1 outline-n-weak"
      role="img"
      :aria-label="reaction.label"
    >
      {{ reaction.emoji }}
    </span>
    <div
      v-if="canReact"
      v-on-click-outside="closePicker"
      class="relative"
      @keydown.esc="closeOnEscape"
    >
      <Button
        ref="actionButton"
        v-tooltip.top="t('CONVERSATION.CONTEXT_MENU.REACTION.ACTION')"
        type="button"
        size="xs"
        color="slate"
        variant="ghost"
        icon="i-lucide-smile-plus"
        :aria-label="t('CONVERSATION.CONTEXT_MENU.REACTION.ACTION')"
        aria-haspopup="dialog"
        :aria-expanded="pickerOpen"
        :disabled="sending || !!reactions?.pending"
        @click="pickerOpen = !pickerOpen"
      />
      <EmojiIconPicker
        v-if="pickerOpen"
        mode="emoji"
        class="bottom-full mb-1.5 max-w-[min(22rem,75vw)]"
        :class="alignEnd ? 'end-0' : 'start-0'"
        :value="reactions?.outgoing?.emoji || ''"
        :show-remove-button="!!reactions?.outgoing"
        @select="react($event.value)"
        @remove="react('')"
      />
    </div>
    <span
      v-if="reactions?.pending"
      class="text-xs text-n-slate-11"
      role="status"
    >
      {{ t('CONVERSATION.CONTEXT_MENU.REACTION.PENDING') }}
    </span>
  </div>
</template>
