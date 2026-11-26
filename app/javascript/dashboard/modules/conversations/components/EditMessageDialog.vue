<script setup>
import { computed, ref, useId } from 'vue';
import { useI18n } from 'vue-i18n';
import MessageApi from 'dashboard/api/inbox/message';
import { useAlert } from 'dashboard/composables';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

const props = defineProps({
  conversationId: { type: [Number, String], required: true },
  messageId: { type: [Number, String], required: true },
  originalContent: { type: String, default: '' },
});

const emit = defineEmits(['close', 'confirmed', 'pending']);

const { t } = useI18n();
const fieldId = useId();
const dialog = ref(null);
const draft = ref('');
const isSaving = ref(false);
const errorCode = ref('');

const errorText = computed(() => {
  const errors = {
    edit_expired: t('CONVERSATION.CONTEXT_MENU.EDIT_MESSAGE.EXPIRED'),
    edit_failed: t('CONVERSATION.CONTEXT_MENU.EDIT_MESSAGE.FAILED'),
    edit_unavailable: t('CONVERSATION.CONTEXT_MENU.EDIT_MESSAGE.UNAVAILABLE'),
    invalid_content: t('CONVERSATION.CONTEXT_MENU.EDIT_MESSAGE.INVALID'),
    edit_pending: t('CONVERSATION.CONTEXT_MENU.EDIT_MESSAGE.PENDING'),
    unknown: t('CONVERSATION.CONTEXT_MENU.EDIT_MESSAGE.UNKNOWN'),
  };

  if (!errorCode.value) return '';
  return Object.hasOwn(errors, errorCode.value)
    ? errors[errorCode.value]
    : errors.unknown;
});

const cannotSave = computed(
  () =>
    isSaving.value ||
    !draft.value.trim() ||
    draft.value === props.originalContent ||
    ['edit_expired', 'edit_unavailable'].includes(errorCode.value)
);

const open = () => {
  draft.value = props.originalContent;
  errorCode.value = '';
  dialog.value.open();
};

const save = async () => {
  if (cannotSave.value) return;
  errorCode.value = '';
  isSaving.value = true;
  const accountUrl = MessageApi.url;
  const { conversationId, messageId } = props;
  const content = draft.value;
  try {
    const { status, data } = await MessageApi.editContent(
      conversationId,
      messageId,
      content
    );
    if (status === 200) {
      emit('confirmed', data);
      dialog.value?.close();
      useAlert(t('CONVERSATION.CONTEXT_MENU.EDIT_MESSAGE.SUCCESS'));
    } else if (status === 202) {
      emit('pending', { conversationId, messageId, content, accountUrl });
      dialog.value?.close();
      useAlert(t('CONVERSATION.CONTEXT_MENU.EDIT_MESSAGE.PENDING'));
    } else {
      errorCode.value = 'unknown';
    }
  } catch (error) {
    errorCode.value = error.response?.data?.error_code || 'unknown';
  } finally {
    isSaving.value = false;
  }
};

defineExpose({ open });
</script>

<template>
  <Dialog
    ref="dialog"
    :title="t('CONVERSATION.CONTEXT_MENU.EDIT_MESSAGE.TITLE')"
    :confirm-button-label="t('CONVERSATION.CONTEXT_MENU.EDIT_MESSAGE.SAVE')"
    :is-loading="isSaving"
    :disable-confirm-button="cannotSave"
    :disable-close="isSaving"
    @confirm="save"
    @close="emit('close')"
  >
    <div class="flex flex-col gap-2" data-clarity-mask="True">
      <TextArea
        :id="fieldId"
        v-model="draft"
        :label="t('CONVERSATION.CONTEXT_MENU.EDIT_MESSAGE.LABEL')"
        :disabled="isSaving"
        auto-height
        autofocus
      />
      <p v-if="errorText" role="alert" class="mb-0 text-sm text-n-ruby-11">
        {{ errorText }}
      </p>
    </div>
  </Dialog>
</template>
