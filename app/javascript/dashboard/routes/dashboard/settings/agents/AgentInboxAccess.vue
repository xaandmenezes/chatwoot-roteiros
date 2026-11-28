<script setup>
import { onMounted, reactive, shallowRef } from 'vue';
import { useI18n } from 'vue-i18n';
import AgentsAPI from 'dashboard/api/agents';
import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  agentId: { type: Number, required: true },
});

const { t } = useI18n();

const inboxes = shallowRef([]);
const levels = reactive({});
const savingInbox = shallowRef(null);

onMounted(async () => {
  try {
    const { data } = await AgentsAPI.getInboxAccess(props.agentId);
    data.forEach(inbox => {
      levels[inbox.id] = inbox.access_level;
    });
    inboxes.value = data;
  } catch {
    useAlert(t('AGENT_MGMT.INBOX_ACCESS.LOAD_ERROR'));
  }
});

const save = async inbox => {
  savingInbox.value = inbox.id;
  try {
    const { data } = await AgentsAPI.updateInboxAccess(
      props.agentId,
      inbox.id,
      levels[inbox.id]
    );
    inboxes.value = inboxes.value.map(row => (row.id === data.id ? data : row));
    levels[inbox.id] = data.access_level;
    useAlert(t('AGENT_MGMT.INBOX_ACCESS.SAVE_SUCCESS'));
  } catch {
    useAlert(t('AGENT_MGMT.INBOX_ACCESS.SAVE_ERROR'));
  } finally {
    savingInbox.value = null;
  }
};
</script>

<template>
  <fieldset v-show="inboxes.length" class="mb-4 min-w-0 space-y-3">
    <legend class="mb-2 text-sm font-semibold text-n-slate-12">
      {{ t('AGENT_MGMT.INBOX_ACCESS.TITLE') }}
    </legend>
    <div
      v-for="inbox in inboxes"
      :key="inbox.id"
      class="flex flex-wrap items-end gap-2"
    >
      <label class="min-w-0 basis-full break-words sm:flex-1">
        {{ inbox.name }}
        <select
          v-model="levels[inbox.id]"
          class="mb-0"
          :disabled="savingInbox !== null"
        >
          <option value="none">{{ t('AGENT_MGMT.INBOX_ACCESS.NONE') }}</option>
          <option value="agent">
            {{ t('AGENT_MGMT.INBOX_ACCESS.AGENT') }}
          </option>
          <option v-if="inbox.supervision_available" value="supervisor">
            {{ t('AGENT_MGMT.INBOX_ACCESS.SUPERVISOR') }}
          </option>
        </select>
      </label>
      <Button
        type="button"
        faded
        slate
        :label="t('AGENT_MGMT.INBOX_ACCESS.SAVE')"
        :disabled="
          savingInbox !== null || inbox.access_level === levels[inbox.id]
        "
        :is-loading="savingInbox === inbox.id"
        @click="save(inbox)"
      />
    </div>
  </fieldset>
</template>
