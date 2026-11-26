<script setup>
/* global axios */
import { computed, onScopeDispose, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useIntervalFn } from '@vueuse/core';
import Button from 'dashboard/components-next/button/Button.vue';
import { useAbortableRequest } from 'dashboard/composables/useAbortableRequest';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { useMapGetter } from 'dashboard/composables/store';

const emit = defineEmits(['labelsChanged']);
const POLL_INTERVAL = 3000;

const { t } = useI18n();
const accountId = useMapGetter('getCurrentAccountId');
const { isAdmin } = useAdmin();
const { run, abort, isPending } = useAbortableRequest();

const sync = ref(null);
const errorMessage = ref('');
const status = computed(() => sync.value?.status);
const enabled = computed(() => isAdmin.value && sync.value?.enabled === true);
const loadFailed = computed(
  () => isAdmin.value && errorMessage.value === 'LOAD_ERROR'
);
const active = computed(() => ['queued', 'running'].includes(status.value));
const finished = computed(() => ['completed', 'failed'].includes(status.value));
const counts = computed(() => ({
  processed: sync.value?.counts?.processed ?? 0,
  updated: sync.value?.counts?.updated ?? 0,
  unchanged: sync.value?.counts?.unchanged ?? 0,
  noLabels: sync.value?.counts?.no_labels ?? 0,
  unmatched: sync.value?.counts?.unmatched ?? 0,
  ambiguous: sync.value?.counts?.ambiguous ?? 0,
}));

async function requestSync(start = false) {
  const account = accountId.value;
  const url = `/api/v1/accounts/${account}/umbler_label_sync`;

  try {
    const response = await run(async signal => {
      const options = { signal, timeout: 10000 };
      const responseForAccount = start
        ? await axios.post(url, {}, options)
        : await axios.get(url, options);
      if (signal.aborted) return undefined;
      return responseForAccount;
    });
    if (!response || account !== accountId.value || !isAdmin.value) return;

    const wasRunning = start || active.value;
    sync.value = response.data;
    errorMessage.value = '';
    if (wasRunning && finished.value && counts.value.updated > 0) {
      emit('labelsChanged');
    }
  } catch (error) {
    if (account !== accountId.value || !isAdmin.value) return;

    if ([401, 403, 404].includes(error?.response?.status)) {
      sync.value = null;
      errorMessage.value = '';
      return;
    }

    if (start) {
      errorMessage.value = 'START_ERROR';
    } else {
      errorMessage.value = sync.value ? 'STATUS_ERROR' : 'LOAD_ERROR';
    }
  }
}

const { resume: startPolling, pause: stopPolling } = useIntervalFn(
  () => {
    if (!isPending.value) requestSync();
  },
  POLL_INTERVAL,
  { immediate: false }
);
onScopeDispose(stopPolling);

watch(
  () => enabled.value && active.value,
  running => {
    if (running) startPolling();
    else stopPolling();
  }
);

watch(
  [accountId, isAdmin],
  ([account, administrator]) => {
    abort();
    stopPolling();
    sync.value = null;
    errorMessage.value = '';
    if (account && administrator) requestSync();
  },
  { immediate: true }
);

const startSync = () => {
  if (!enabled.value || active.value || isPending.value) return;
  errorMessage.value = '';
  requestSync(true);
};

const loadStatus = () => {
  if (!isPending.value) requestSync();
};
</script>

<template>
  <div>
    <div v-if="enabled || loadFailed" class="px-6 pb-3">
      <div
        class="flex flex-wrap items-center gap-x-3 gap-y-2 max-w-5xl mx-auto"
      >
        <Button
          v-if="enabled"
          type="button"
          icon="i-lucide-tags"
          size="sm"
          color="slate"
          variant="outline"
          :label="t('CONTACTS_LAYOUT.UMBLER_LABEL_SYNC.ACTION')"
          :disabled="active || isPending"
          @click="startSync"
        />
        <Button
          v-else
          type="button"
          size="sm"
          color="slate"
          variant="outline"
          :label="t('CONTACTS_LAYOUT.UMBLER_LABEL_SYNC.RETRY')"
          :disabled="isPending"
          @click="loadStatus"
        />
        <div role="status" class="min-w-0 text-sm text-n-slate-11">
          <p v-if="loadFailed" class="text-n-ruby-11">
            {{ t('CONTACTS_LAYOUT.UMBLER_LABEL_SYNC.LOAD_ERROR') }}
          </p>
          <p v-else-if="errorMessage === 'START_ERROR'" class="text-n-ruby-11">
            {{ t('CONTACTS_LAYOUT.UMBLER_LABEL_SYNC.START_ERROR') }}
          </p>
          <p v-else-if="errorMessage === 'STATUS_ERROR'" class="text-n-ruby-11">
            {{ t('CONTACTS_LAYOUT.UMBLER_LABEL_SYNC.STATUS_ERROR') }}
          </p>
          <p v-else-if="status === 'queued'">
            {{ t('CONTACTS_LAYOUT.UMBLER_LABEL_SYNC.QUEUED') }}
          </p>
          <p v-else-if="status === 'running'">
            {{ t('CONTACTS_LAYOUT.UMBLER_LABEL_SYNC.RUNNING', counts) }}
          </p>
          <p v-if="status === 'failed'" class="text-n-ruby-11">
            {{ t('CONTACTS_LAYOUT.UMBLER_LABEL_SYNC.FAILED') }}
          </p>
          <p v-if="finished">
            {{ t('CONTACTS_LAYOUT.UMBLER_LABEL_SYNC.RESULT', counts) }}
          </p>
        </div>
      </div>
    </div>
  </div>
</template>
