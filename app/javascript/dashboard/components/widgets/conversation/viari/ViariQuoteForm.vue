<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAbortableRequest } from 'dashboard/composables/useAbortableRequest';

const props = defineProps({
  catalog: { type: Object, required: true },
  read: { type: Function, required: true },
  itemOnly: Boolean,
  initial: { type: Object, default: null },
});
const emit = defineEmits(['save']);
const { t } = useI18n();
const now = new Date();
const today = [
  now.getFullYear(),
  String(now.getMonth() + 1).padStart(2, '0'),
  String(now.getDate()).padStart(2, '0'),
].join('-');
const header = ref({
  periodoInicio: today,
  periodoFim: today,
  dataValidade: today,
  canalVendaId: '',
  percentualSinal: 35,
  descontoManual: 0,
  obsInternas: '',
  msgCliente: '',
});
if (props.initial) {
  ['periodoInicio', 'periodoFim', 'dataValidade'].forEach(key => {
    header.value[key] = props.initial[key]?.slice(0, 10) || today;
  });
  header.value.canalVendaId = props.initial.canalVenda?.id || '';
}
const items = ref([]);
const blankItem = () => ({
  produtoId: '',
  agendaId: '',
  qtdAdt: 1,
  qtdChd: 0,
  qtdInf: 0,
  qtdSen: 0,
  qtdFree: 0,
});
const item = ref(blankItem());
const agendas = ref([]);
const tariffs = ref([]);
const chosen = ref([]);
const err = ref('');
const pax = ['qtdAdt', 'qtdChd', 'qtdInf', 'qtdSen', 'qtdFree'];
const channel = computed(() =>
  props.catalog.canais.find(c => c.id === header.value.canalVendaId)
);
const scheduleRequests = useAbortableRequest();
const tariffRequests = useAbortableRequest();
let lookup = 0;
watch(
  () => [
    item.value.produtoId,
    header.value.periodoInicio,
    header.value.periodoFim,
    header.value.canalVendaId,
  ],
  async () => {
    lookup += 1;
    const sequence = lookup;
    agendas.value = [];
    tariffs.value = [];
    chosen.value = [];
    item.value.agendaId = '';
    err.value = '';
    if (
      !item.value.produtoId ||
      !header.value.periodoInicio ||
      !header.value.periodoFim
    )
      return;
    try {
      const dates = await scheduleRequests.run(signal =>
        props.read(
          'agendas',
          {
            produtoId: item.value.produtoId,
            dataInicio: header.value.periodoInicio,
            dataFim: header.value.periodoFim,
          },
          signal
        )
      );
      if (dates && sequence === lookup) agendas.value = dates.agendas;
    } catch {
      if (sequence === lookup) err.value = t('VIARI.ERROR');
    }
  }
);
watch(
  () => item.value.agendaId,
  async agendaId => {
    tariffRequests.abort();
    tariffs.value = [];
    chosen.value = [];
    err.value = '';
    if (!agendaId) return;
    const data = agendas.value
      .find(a => a.id === agendaId)
      ?.dataAgenda.slice(0, 10);
    try {
      const prices = await tariffRequests.run(signal =>
        props.read(
          'tarifas',
          {
            produtoId: item.value.produtoId,
            data,
            grupoTarifaId: channel.value?.grupoTarifaId,
          },
          signal
        )
      );
      if (prices && item.value.agendaId === agendaId)
        tariffs.value = prices.itens;
    } catch {
      err.value = t('VIARI.ERROR');
    }
  }
);
function add() {
  const next = { ...item.value };
  if (chosen.value.length) next.itensSelecionados = [...chosen.value];
  if (props.itemOnly) {
    emit('save', {
      ...next,
      dataDesejada: agendas.value
        .find(a => a.id === next.agendaId)
        .dataAgenda.slice(0, 10),
    });
    return;
  }
  items.value.push(next);
  item.value = blankItem();
}
function save() {
  emit('save', {
    ...header.value,
    canalVendaId: header.value.canalVendaId || null,
    itens: items.value,
  });
}
</script>

<template>
  <form class="grid gap-2" @submit.prevent="save">
    <label
      v-for="field in ['periodoInicio', 'periodoFim', 'dataValidade']"
      :key="field"
    >
      <span>{{ t('VIARI.' + field) }}</span>
      <input v-model="header[field]" type="date" required />
    </label>
    <label>
      <span>{{ t('VIARI.CHANNEL') }}</span>
      <select v-model="header.canalVendaId">
        <option value="">—</option>
        <option v-for="c in catalog.canais" :key="c.id" :value="c.id">
          {{ c.nome }}
        </option>
      </select>
    </label>
    <label>
      <span>{{ t('VIARI.PRODUCT') }}</span>
      <select v-model="item.produtoId">
        <option value="">—</option>
        <option v-for="p in catalog.produtos" :key="p.id" :value="p.id">
          {{ p.nome }}
        </option>
      </select>
    </label>
    <label>
      <span>{{ t('VIARI.SCHEDULE') }}</span>
      <select v-model="item.agendaId">
        <option value="">—</option>
        <option v-for="a in agendas" :key="a.id" :value="a.id">
          {{ a.dataAgenda?.slice(0, 10) }} · {{ a.horario }} ·
          {{ a.vagasDisponiveis }}
        </option>
      </select>
    </label>
    <div v-for="sub in tariffs" :key="sub.itemId">
      <label
        ><input v-model="chosen" type="checkbox" :value="sub.itemId" />{{
          sub.itemNome
        }}
        · {{ sub.precos.ADT?.normal ?? sub.precos.ADT }}</label
      >
    </div>
    <label v-for="p in pax" :key="p">
      <span>{{ t('VIARI.' + p) }}</span>
      <input v-model.number="item[p]" type="number" min="0" step="1" />
    </label>
    <button
      type="button"
      :disabled="
        !item.agendaId ||
        tariffRequests.isPending.value ||
        !!err ||
        !pax.some(p => item[p] > 0)
      "
      @click="add"
    >
      {{ t('VIARI.ADD_ITEM') }}
    </button>
    <template v-if="!itemOnly">
      <div v-for="(i, n) in items" :key="n">
        {{ catalog.produtos.find(p => p.id === i.produtoId)?.nome }} ·
        {{ pax.reduce((a, k) => a + i[k], 0) }} {{ t('VIARI.PAX') }}
        <button type="button" @click="items.splice(n, 1)">
          {{ t('VIARI.REMOVE') }}
        </button>
      </div>
      <label>
        <span>{{ t('VIARI.DEPOSIT') }}</span>
        <input
          v-model.number="header.percentualSinal"
          type="number"
          min="0"
          max="100"
          required
        />
      </label>
      <label>
        <span>{{ t('VIARI.DISCOUNT') }}</span>
        <input
          v-model.number="header.descontoManual"
          type="number"
          min="0"
          step=".01"
          required
        />
      </label>
      <label>
        <span>{{ t('VIARI.NOTES') }}</span>
        <textarea v-model="header.obsInternas" />
      </label>
      <label>
        <span>{{ t('VIARI.MESSAGE') }}</span>
        <textarea v-model="header.msgCliente" />
      </label>
      <p v-if="err" role="alert">{{ err }}</p>
      <button :disabled="!items.length" type="submit">
        {{ t('VIARI.CREATE_QUOTE') }}
      </button>
    </template>
  </form>
</template>
