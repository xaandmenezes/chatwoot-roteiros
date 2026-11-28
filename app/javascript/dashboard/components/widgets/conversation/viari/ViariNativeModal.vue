<script setup>
import { onBeforeUnmount, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
const props = defineProps({ session: { type: Object, required: true } });
const emit = defineEmits(['close', 'saved', 'navigate', 'refresh']);
const { t } = useI18n();
const frame = ref(null);
const dialog = ref(null);
function receive(event) {
  if (
    event.origin !== props.session.origin ||
    event.source !== frame.value?.contentWindow ||
    event.data?.channel !== props.session.channel
  )
    return;
  if (event.data.type === 'viari:refresh') emit('refresh');
  if (event.data.type === 'viari:saved') emit('saved', event.data);
  if (event.data.type === 'viari:navigate') emit('navigate', event.data);
  if (event.data.type === 'viari:close') emit('close');
}
onMounted(() => {
  dialog.value.showModal();
  window.addEventListener('message', receive);
});
onBeforeUnmount(() => window.removeEventListener('message', receive));
</script>

<template>
  <Teleport to="body">
    <dialog
      ref="dialog"
      class="fixed inset-0 z-50 m-auto w-full max-w-6xl border-0 bg-transparent p-4 backdrop:bg-black/50"
      @cancel.prevent="emit('close')"
    >
      <section
        role="dialog"
        aria-modal="true"
        :aria-label="t('VIARI.NATIVE_TITLE')"
        class="flex h-[90vh] w-full max-w-6xl flex-col rounded-xl bg-n-background shadow-xl"
      >
        <header
          class="flex items-center justify-between border-b border-n-weak p-3"
        >
          <h2 class="m-0 text-base font-semibold">
            {{ t('VIARI.NATIVE_TITLE') }}
          </h2>
          <button
            autofocus
            type="button"
            class="rounded p-2 text-n-brand"
            @click="emit('close')"
          >
            {{ t('VIARI.CLOSE') }}
          </button>
        </header>
        <iframe
          ref="frame"
          :src="session.url"
          :title="t('VIARI.NATIVE_TITLE')"
          sandbox="allow-scripts allow-same-origin allow-forms allow-downloads"
          referrerpolicy="no-referrer"
          allow="clipboard-write"
          class="w-full flex-1 border-0"
        />
      </section>
    </dialog>
  </Teleport>
</template>
