<script setup>
import { ref } from 'vue';
import { useStore } from 'vuex';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import ConversationApi from 'dashboard/api/inbox/conversation';
import Button from 'next/button/Button.vue';

const props = defineProps({
  conversationId: { type: Number, required: true },
  messageId: { type: Number, required: true },
});
const store = useStore();
const { t } = useI18n();
const loading = ref(false);

const retry = async () => {
  if (loading.value) return;
  loading.value = true;
  const accountUrl = ConversationApi.url;
  try {
    const { data } = await ConversationApi.repairHistoricalMedia(
      props.conversationId,
      props.messageId
    );
    if (accountUrl === ConversationApi.url) {
      await store.dispatch('updateMessage', data);
    }
  } catch {
    useAlert(t('CONVERSATION.RYZE_HISTORY.MEDIA_ERROR'));
  } finally {
    loading.value = false;
  }
};
</script>

<template>
  <li class="flex justify-center">
    <Button
      sm
      ghost
      :label="t('CONVERSATION.RYZE_HISTORY.RETRY_MEDIA')"
      :disabled="loading"
      @click="retry"
    />
  </li>
</template>
