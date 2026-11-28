<script setup>
import { ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
const props = defineProps({
  reservation: { type: Object, required: true },
  command: { type: Function, required: true },
});
const emit = defineEmits(['changed']);
const { t } = useI18n();
const fields = ['qtdAdt', 'qtdChd', 'qtdInf', 'qtdSen', 'qtdFree'];
const quantities = ref(
  Object.fromEntries(fields.map(k => [k, props.reservation[k]]))
);
const preview = ref(null);
const reason = ref('');
const amount = ref(0);
const approved = ref(false);
const error = ref('');
const busy = ref(false);
watch(
  quantities,
  () => {
    preview.value = null;
    approved.value = false;
  },
  { deep: true, flush: 'sync' }
);
async function submit() {
  if (busy.value) return;
  busy.value = true;
  error.value = '';
  try {
    const scope = { reservaId: props.reservation.id };
    if (!preview.value) {
      preview.value = await props.command(
        'reserva_cancelamento_parcial_previa',
        { ...scope, dados: { ...quantities.value } }
      );
      amount.value = preview.value.referenciaAplicavel;
    } else {
      await props.command('reserva_editar', {
        ...scope,
        dados: {
          ...quantities.value,
          cancelamentoParcial: {
            versao: preview.value.versao,
            valor: amount.value,
            motivo: reason.value,
            confirmarAcimaReferencia: approved.value,
          },
        },
      });
      preview.value = null;
      emit('changed');
    }
  } catch (e) {
    error.value = e.response?.data?.error?.mensagem || t('VIARI.ERROR');
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <details>
    <summary>{{ t('VIARI.PARTIAL_CANCEL') }}</summary>
    <form class="grid gap-2" @submit.prevent="submit">
      <fieldset class="grid gap-2" :disabled="busy">
        <label v-for="key in fields" :key="key">
          <span>{{ t('VIARI.' + key) }}</span>
          <input
            v-model.number="quantities[key]"
            type="number"
            min="0"
            :max="reservation[key]"
            required
          />
        </label>
        <template v-if="preview">
          <p>
            {{ t('VIARI.BALANCE') }} {{ preview.saldo }} ·
            {{ t('VIARI.TOTAL_PAID') }} {{ preview.pago }}
          </p>
          <label
            ><span>{{ t('VIARI.RETAIN') }}</span
            ><input
              v-model.number="amount"
              type="number"
              min="0"
              step=".01"
              required
            />
          </label>
          <label
            ><span>{{ t('VIARI.REASON') }}</span
            ><input v-model.trim="reason" required />
          </label>
          <label v-if="amount > preview.referenciaAplicavel"
            ><input v-model="approved" type="checkbox" />{{
              t('VIARI.ABOVE_REFERENCE')
            }}</label
          >
        </template>
        <button
          :disabled="
            fields.every(k => quantities[k] === reservation[k]) ||
            fields.every(k => quantities[k] === 0) ||
            (preview && amount > preview.referenciaAplicavel && !approved)
          "
        >
          {{ t(preview ? 'VIARI.CONFIRM_PARTIAL' : 'VIARI.PREVIEW') }}
        </button>
      </fieldset>
    </form>
    <p v-if="error" role="alert">{{ error }}</p>
  </details>
</template>
