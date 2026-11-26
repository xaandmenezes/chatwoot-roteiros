<script setup>
import { computed, onBeforeUnmount, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import MessageApi from 'dashboard/api/inbox/message';
import { useAlert } from 'dashboard/composables';

const props = defineProps({
  conversationId: { type: [Number, String], required: true },
  messageId: { type: [Number, String], required: true },
  createdAt: { type: Number, required: true },
  canDeleteForEveryone: { type: Boolean, required: true },
});
const emit = defineEmits(['close', 'confirmed']);
const { t } = useI18n();
const DELETE_WINDOW_MS = 15 * 60 * 1000;
const deadline = computed(() => props.createdAt * 1000 + DELETE_WINDOW_MS);
const dialog = ref(null);
const choice = ref('');
const busy = ref(false);
const expired = ref(false);
const error = ref('');
let expiryTimer;
const remoteAvailable = computed(
  () => props.canDeleteForEveryone && !expired.value
);
const remoteDescription = computed(() => {
  if (expired.value) return t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.EXPIRED');
  if (remoteAvailable.value)
    return t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.EVERYONE_DESCRIPTION');
  return t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.UNAVAILABLE');
});
const canConfirm = computed(
  () =>
    !busy.value &&
    (choice.value === 'local' ||
      (choice.value === 'everyone' && remoteAvailable.value))
);
const confirmLabel = computed(() => {
  if (choice.value === 'local')
    return t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.LOCAL');
  if (choice.value === 'everyone')
    return t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.EVERYONE');
  return t('CONVERSATION.CONTEXT_MENU.DELETE');
});

function expire() {
  expired.value = true;
  if (choice.value === 'everyone') choice.value = '';
}

function open() {
  const remaining = deadline.value - Date.now();
  if (remaining <= 0) expire();
  else expiryTimer = setTimeout(expire, remaining);
  dialog.value.open();
}

async function remove() {
  if (Date.now() >= deadline.value) expire();
  if (!canConfirm.value) return;
  const local = choice.value === 'local';
  busy.value = true;
  error.value = '';
  try {
    const { status, data } = local
      ? await MessageApi.deleteOnlyInChatwoot(
          props.conversationId,
          props.messageId
        )
      : await MessageApi.deleteForEveryone(
          props.conversationId,
          props.messageId
        );
    if (status === 200) {
      emit('confirmed', data);
      useAlert(
        local
          ? t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.LOCAL_DONE')
          : t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.EVERYONE_DONE')
      );
    } else if (!local && status === 202) {
      useAlert(t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.PENDING'));
    } else {
      error.value = t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.UNKNOWN');
      return;
    }
    dialog.value?.close();
  } catch (e) {
    if (e.response?.data?.error_code === 'delete_expired') {
      expire();
      error.value = t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.EXPIRED');
    } else {
      error.value =
        e.response?.status === 409
          ? t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.CONFLICT')
          : t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.UNKNOWN');
    }
  } finally {
    busy.value = false;
  }
}

onBeforeUnmount(() => clearTimeout(expiryTimer));
defineExpose({ open });
</script>

<template>
  <Dialog
    ref="dialog"
    type="alert"
    :title="t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.TITLE')"
    :confirm-button-label="confirmLabel"
    :disable-confirm-button="!canConfirm"
    :disable-close="busy"
    :is-loading="busy"
    @confirm="remove"
    @close="emit('close')"
  >
    <fieldset class="flex flex-col gap-4" :disabled="busy">
      <legend class="sr-only">
        {{ t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.TITLE') }}
      </legend>
      <label class="flex items-start gap-2">
        <input
          v-model="choice"
          type="radio"
          name="delete-scope"
          value="local"
          class="mt-1"
        />
        <span>
          <span class="block font-medium">{{
            t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.LOCAL')
          }}</span>
          <span class="text-sm text-n-slate-11">{{
            t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.LOCAL_DESCRIPTION')
          }}</span>
        </span>
      </label>
      <label class="flex items-start gap-2">
        <input
          v-model="choice"
          type="radio"
          name="delete-scope"
          value="everyone"
          class="mt-1"
          :disabled="!remoteAvailable"
        />
        <span>
          <span class="block font-medium">{{
            t('CONVERSATION.CONTEXT_MENU.DELETE_SCOPE.EVERYONE')
          }}</span>
          <span class="text-sm text-n-slate-11">{{ remoteDescription }}</span>
        </span>
      </label>
      <p v-if="error" role="alert" class="mb-0 text-sm text-n-ruby-11">
        {{ error }}
      </p>
    </fieldset>
  </Dialog>
</template>
