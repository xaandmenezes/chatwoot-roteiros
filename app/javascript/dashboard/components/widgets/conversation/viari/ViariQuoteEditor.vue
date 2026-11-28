<script setup>
import { ref } from 'vue';
import PassengerForm from './ViariPassengerForm.vue';
import QuoteForm from './ViariQuoteForm.vue';
import { useI18n } from 'vue-i18n';
const props = defineProps({
  quote: { type: Object, required: true },
  catalog: { type: Object, default: null },
  read: { type: Function, required: true },
});
const emit = defineEmits(['edit']);
const { t } = useI18n();
const q = props.quote;
const head = ref({
  periodoInicio: q.periodoInicio?.slice(0, 10),
  periodoFim: q.periodoFim?.slice(0, 10),
  dataValidade: q.dataValidade?.slice(0, 10),
  percentualSinal: Number(q.percentualSinal),
  descontoManual: Number(q.descontoManualGeral ?? q.descontoManual ?? 0),
  obsInternas: q.obsInternas || '',
  msgCliente: q.msgCliente || '',
  canalVendaId: q.canalVenda?.id ?? q.canalVendaId ?? null,
});
const coupon = ref('');
const editing = ref(null);
const rows = ['qtdAdt', 'qtdChd', 'qtdInf', 'qtdSen', 'qtdFree'];
function editItem(item) {
  editing.value = {
    itemId: item.id,
    dataDesejada: item.dataDesejada?.slice(0, 10),
    agendaId: item.agendaId || null,
    itensSelecionados: (item.detalhes || [])
      .filter(detail => detail.incluido)
      .map(detail => detail.itemProdutoId),
    ...Object.fromEntries(rows.map(k => [k, Number(item[k] || 0)])),
  };
}
</script>

<template>
  <details>
    <summary>{{ t('VIARI.EDIT_QUOTE') }}</summary>
    <form
      class="grid gap-2"
      @submit.prevent="emit('edit', { operacao: 'cabecalho', ...head })"
    >
      <label
        v-for="key in ['periodoInicio', 'periodoFim', 'dataValidade']"
        :key="key"
      >
        <span>{{ t('VIARI.' + key) }}</span>
        <input v-model="head[key]" type="date" required />
      </label>
      <label>
        <span>{{ t('VIARI.DEPOSIT') }}</span>
        <input
          v-model.number="head.percentualSinal"
          type="number"
          min="0"
          max="100"
          required
        />
      </label>
      <label>
        <span>{{ t('VIARI.DISCOUNT') }}</span>
        <input
          v-model.number="head.descontoManual"
          type="number"
          min="0"
          step=".01"
        />
      </label>
      <label>
        <span>{{ t('VIARI.NOTES') }}</span>
        <textarea v-model="head.obsInternas" />
      </label>
      <label>
        <span>{{ t('VIARI.MESSAGE') }}</span>
        <textarea v-model="head.msgCliente" />
      </label>
      <button>{{ t('VIARI.SAVE') }}</button>
    </form>
    <label>
      <span>{{ t('VIARI.COUPON') }}</span>
      <input v-model.trim="coupon" />
    </label>
    <button
      :disabled="!coupon"
      @click="emit('edit', { operacao: 'cupom_aplicar', cupomCodigo: coupon })"
    >
      {{ t('VIARI.APPLY') }}
    </button>
    <button
      v-if="quote.cupom || quote.cupomId"
      @click="emit('edit', { operacao: 'cupom_remover' })"
    >
      {{ t('VIARI.REMOVE_COUPON') }}
    </button>
    <div v-for="item in quote.itens" :key="item.id">
      <button @click="editItem(item)">
        {{ item.produto?.nome || item.produtoNome }} ·
        {{ t('VIARI.EDIT_QUOTE') }}
      </button>
      <button
        @click="emit('edit', { operacao: 'item_remover', itemId: item.id })"
      >
        {{ t('VIARI.REMOVE') }}
      </button>
    </div>
    <details>
      <summary>{{ t('VIARI.PASSENGERS') }}</summary>
      <p v-for="p in quote.passageiros" :key="p.id">
        {{ p.nome }} · {{ p.tipoPax }}
        <button
          @click="
            emit('edit', { operacao: 'passageiro_remover', passageiroId: p.id })
          "
        >
          {{ t('VIARI.REMOVE') }}
        </button>
      </p>
      <PassengerForm
        @save="
          dados => emit('edit', { operacao: 'passageiro_adicionar', ...dados })
        "
      />
    </details>
    <details v-if="catalog">
      <summary>{{ t('VIARI.ADD_ITEM') }}</summary>
      <QuoteForm
        :catalog="catalog"
        :read="read"
        item-only
        :initial="quote"
        @save="dados => emit('edit', { operacao: 'item_adicionar', ...dados })"
      />
    </details>
    <form
      v-if="editing"
      @submit.prevent="emit('edit', { operacao: 'item_editar', ...editing })"
    >
      <label v-for="key in rows" :key="key">
        <span>{{ t('VIARI.' + key) }}</span>
        <input v-model.number="editing[key]" type="number" min="0" required />
      </label>
      <button>{{ t('VIARI.SAVE') }}</button>
    </form>
  </details>
</template>
