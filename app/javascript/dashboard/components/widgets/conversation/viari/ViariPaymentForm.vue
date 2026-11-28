<script setup>
import { ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
const props = defineProps({
  order: { type: Object, required: true },
  partners: { type: Array, required: true },
  command: { type: Function, required: true },
  accounts: { type: Array, required: true },
});
const emit = defineEmits(['paid']);
const { t } = useI18n();
const methods = [
  'pix',
  'cartao_credito',
  'cartao_debito',
  'dinheiro',
  'boleto',
  'transferencia',
];
const draft = ref({
  metodo: 'pix',
  tipoPagamento: 'sinal',
  valor: 0,
  recebedorTipo: 'empresa',
  parceiroId: '',
  parcelas: 1,
  data: '',
  contaBancariaId: '',
});
const preview = ref(null);
const reservationId = ref('');
watch(
  reservationId,
  () => {
    preview.value = null;
  },
  { flush: 'sync' }
);
const busy = ref(false);
const error = ref('');
watch(
  draft,
  () => {
    preview.value = null;
  },
  { deep: true, flush: 'sync' }
);
function payload() {
  const dados = { ...draft.value };
  if (dados.recebedorTipo !== 'parceiro') delete dados.parceiroId;
  if (!dados.contaBancariaId) delete dados.contaBancariaId;
  if (!dados.data) delete dados.data;
  if (dados.metodo !== 'cartao_credito') dados.parcelas = 1;
  return reservationId.value
    ? { reservaId: reservationId.value, dados }
    : { grupoId: props.order.grupoId, dados };
}
async function submit() {
  if (busy.value) return;
  busy.value = true;
  error.value = '';
  try {
    if (!preview.value)
      preview.value = await props.command('pagamento_previa', payload());
    else {
      await props.command('pagamento_registrar', payload());
      preview.value = null;
      draft.value.valor = 0;
      emit('paid');
    }
  } catch (e) {
    error.value = e.response?.data?.error?.mensagem || t('VIARI.ERROR');
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <form class="grid gap-2" @submit.prevent="submit">
    <strong
      >{{ t('VIARI.ORDER') }} ·
      {{ order.codigo || order.os?.codigo || order.grupoId }}</strong
    >
    <fieldset class="grid gap-2" :disabled="busy">
      <label v-if="order.reservas?.length"
        ><span>{{ t('VIARI.TARGET') }}</span>
        <select v-model="reservationId">
          <option value="">{{ t('VIARI.ORDER') }} {{ order.codigo }}</option>
          <option
            v-for="r in order.reservas.filter(
              r => r.orcamentoId && !['cancelada', 'noshow'].includes(r.status)
            )"
            :key="r.id"
            :value="r.id"
          >
            {{ r.agenda.produto.nome }} · {{ r.voucherCode }}
          </option>
        </select>
      </label>
      <label>
        <span>{{ t('VIARI.TYPE') }}</span>
        <select v-model="draft.tipoPagamento">
          <option
            v-for="type in [
              'sinal',
              'pagamento_parcial',
              'pagamento_total',
              'acerto',
            ]"
            :key="type"
            :value="type"
          >
            {{ t('VIARI.' + type) }}
          </option>
        </select>
      </label>
      <label>
        <span>{{ t('VIARI.METHOD') }}</span>
        <select v-model="draft.metodo">
          <option
            v-for="m in methods"
            :key="m"
            :value="m"
            :disabled="
              draft.tipoPagamento === 'pagamento_total' &&
              !['pix', 'cartao_credito', 'cartao_debito'].includes(m)
            "
          >
            {{ t('VIARI.' + m) }}
          </option>
        </select>
      </label>
      <label>
        <span>{{ t('VIARI.AMOUNT') }}</span>
        <input
          v-model.number="draft.valor"
          type="number"
          step=".01"
          min=".01"
          required
        />
      </label>
      <label v-if="draft.metodo === 'cartao_credito'">
        <span>{{ t('VIARI.INSTALLMENTS') }}</span>
        <input
          v-model.number="draft.parcelas"
          type="number"
          min="1"
          max="12"
          required
        />
      </label>
      <label>
        <span>{{ t('VIARI.RECEIVER') }}</span>
        <select v-model="draft.recebedorTipo">
          <option value="empresa">{{ t('VIARI.COMPANY') }}</option>
          <option v-if="partners.length" value="parceiro">
            {{ t('VIARI.PARTNER') }}
          </option>
        </select>
      </label>
      <label v-if="draft.recebedorTipo === 'parceiro'">
        <span>{{ t('VIARI.PARTNER') }}</span>
        <select v-model="draft.parceiroId" required>
          <option value="">—</option>
          <option
            v-for="p in partners.filter(i => i.ativo !== false)"
            :key="p.id"
            :value="p.id"
          >
            {{ p.nome }}
          </option>
        </select>
      </label>
      <label>
        <span>{{ t('VIARI.DATE') }}</span>
        <input v-model="draft.data" type="date" />
      </label>
      <label v-if="accounts.length">
        <span>{{ t('VIARI.BANK_SELECT') }}</span>
        <select v-model="draft.contaBancariaId">
          <option value="">—</option>
          <option
            v-for="account in accounts"
            :key="account.id"
            :value="account.id"
          >
            {{ account.nome }}
          </option>
        </select>
      </label>
      <p v-if="preview">
        {{ t('VIARI.BALANCE') }} {{ preview.saldo }} · {{ preview.condicao }} ·
        {{ t('VIARI.AMOUNT') }} {{ draft.valor }} ·
        {{ t('VIARI.' + draft.metodo) }}
      </p>
      <button :disabled="preview && draft.valor > preview.saldo">
        {{ t(preview ? 'VIARI.CONFIRM_PAY' : 'VIARI.PREVIEW') }}
      </button>
    </fieldset>
    <p v-if="error" role="alert">{{ error }}</p>
  </form>
</template>
