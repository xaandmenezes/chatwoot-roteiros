<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import ApiClient from 'dashboard/api/ApiClient';
import { useAccount } from 'dashboard/composables/useAccount';

const api = new ApiClient('integrations/viari_settings', {
  accountScoped: true,
});
const { accountId } = useAccount();
const { t } = useI18n();
const form = reactive({ origin: '', namespace: '', api_key: '' });
const mappings = ref([]);
const origins = ref([]);
const savedKey = ref(false);
const confirmDisable = ref(false);
const status = ref('');
const busy = ref(false);
const context = computed(() => accountId.value);

function load(data) {
  origins.value = data.origins;
  savedKey.value = data.has_key;
  form.origin = data.origin || data.origins[0] || '';
  form.namespace = data.namespace || '';
  form.api_key = '';
  mappings.value = Object.entries(data.actors || {}).map(([agent, actor]) => ({
    agent,
    actor,
  }));
}
async function perform(operation) {
  if (busy.value) return;
  busy.value = true;
  const original = context.value;
  status.value = '';
  try {
    const result = await operation();
    if (original === context.value) load(result.data);
    status.value = t('VIARI.READY');
  } catch {
    status.value = t('VIARI.CONFIG_ERROR');
  } finally {
    busy.value = false;
  }
}
async function save() {
  const actors = Object.fromEntries(
    mappings.value.map(m => [m.agent.trim(), m.actor.trim()])
  );
  if (Object.keys(actors).length !== mappings.value.length) {
    status.value = t('VIARI.CONFIG_ERROR');
    return;
  }
  await perform(() => window.axios.patch(api.url, { ...form, actors }));
}
onMounted(() => perform(() => window.axios.get(api.url)));
</script>

<template>
  <form class="flex max-w-xl flex-col gap-4 p-6" @submit.prevent="save">
    <h1>{{ t('VIARI.TITLE') }}</h1>
    <label>
      <span>{{ t('VIARI.ORIGIN') }}</span>
      <select v-model="form.origin" required>
        <option v-for="url in origins" :key="url">{{ url }}</option>
      </select>
    </label>
    <label>
      <span>{{ t('VIARI.TENANT') }}</span>
      <input v-model.trim="form.namespace" required />
    </label>
    <label>
      <span>{{ t('VIARI.API_KEY') }}</span>
      <input
        v-model="form.api_key"
        autocomplete="new-password"
        type="password"
        :required="!savedKey"
        :placeholder="savedKey ? '••••••••' : ''"
      />
    </label>
    <div v-for="(mapping, i) in mappings" :key="i" class="flex gap-2">
      <label>
        <span>{{ t('VIARI.AGENT') }}</span>
        <input v-model="mapping.agent" required pattern="[1-9][0-9]*" />
      </label>
      <label>
        <span>{{ t('VIARI.ACTOR') }}</span>
        <input v-model="mapping.actor" required />
      </label>
      <button type="button" @click="mappings.splice(i, 1)">
        {{ t('VIARI.REMOVE') }}
      </button>
    </div>
    <button type="button" @click="mappings.push({ agent: '', actor: '' })">
      {{ t('VIARI.ADD_ACTOR') }}
    </button>
    <button :disabled="busy" type="submit">{{ t('VIARI.SAVE') }}</button>
    <label v-if="savedKey"
      ><input v-model="confirmDisable" type="checkbox" />{{
        t('VIARI.DISABLE')
      }}</label
    >
    <button
      v-if="confirmDisable"
      type="button"
      :disabled="busy"
      @click="
        perform(async () => {
          await window.axios.delete(api.url);
          confirmDisable = false;
          return window.axios.get(api.url);
        })
      "
    >
      {{ t('VIARI.DISABLE') }}
    </button>
    <p role="status">{{ status }}</p>
  </form>
</template>
