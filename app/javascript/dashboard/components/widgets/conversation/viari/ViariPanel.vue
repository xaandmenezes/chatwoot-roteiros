<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { useAbortableRequest } from 'dashboard/composables/useAbortableRequest';
import api from 'dashboard/api/integrations/viari';
import NativeModal from './ViariNativeModal.vue';
import { runIntention } from './intention';

const props = defineProps({
  conversationId: { type: Number, required: true },
  contact: { type: Object, required: true },
});
const { t, n } = useI18n();
const request = useAbortableRequest();
const context = ref(null);
const detail = ref(null);
const selected = ref('');
const negotiations = ref([]);
const negotiation = computed(() =>
  negotiations.value.find(item => item.id === selected.value)
);
const stage = ref('quote');
const selectedGroup = ref('');
const selectedQuote = ref('');
const selectedReservation = ref('');
const relatedReservations = computed(() =>
  negotiations.value.filter(
    item =>
      item.tipo === 'reserva' &&
      item.reservaIds.some(id => negotiation.value?.reservaIds.includes(id))
  )
);
const relatedQuotes = computed(() =>
  negotiations.value.filter(
    item =>
      item.tipo === 'orcamento' &&
      item.orcamentoIds.some(id => negotiation.value?.orcamentoIds.includes(id))
  )
);
const activeNegotiation = computed(() =>
  stage.value === 'quote'
    ? negotiations.value.find(item => item.id === selectedQuote.value)
    : negotiations.value.find(
        item => item.tipo === 'os' && item.grupoId === selectedGroup.value
      ) ||
      negotiations.value.find(item => item.id === selectedReservation.value) ||
      negotiation.value
);
const error = ref('');
const session = ref(null);
const MODAL_REFRESH_INTERVAL = 15000;
let refreshTimer;
watch(session, value => {
  clearInterval(refreshTimer);
  if (value)
    refreshTimer = setInterval(() => {
      if (!request.isPending.value) run(refresh);
    }, MODAL_REFRESH_INTERVAL);
});
onBeforeUnmount(() => clearInterval(refreshTimer));
const candidates = ref(null);
const linking = ref(false);
const linkingDialog = ref(null);
watch(linking, value => {
  if (value) linkingDialog.value.showModal();
  else linkingDialog.value.close();
});
const proposal = ref('');
const can = action => context.value?.acoes?.includes(action);
const items = computed(() => activeNegotiation.value?.passeios || []);
const totals = computed(() => activeNegotiation.value?.financeiro);
const pax = ['Adt', 'Chd', 'Inf', 'Sen', 'Free'];
const money = value =>
  value == null
    ? '—'
    : n(Number(value), { style: 'currency', currency: 'BRL' });
const date = value =>
  value ? value.slice(0, 10).split('-').reverse().join('/') : '—';
async function run(operation) {
  error.value = '';
  try {
    await request.run(operation);
  } catch (e) {
    error.value = e.response?.data?.error?.mensagem || t('VIARI.ERROR');
  }
}
const read = (action, params, signal) =>
  api.read(props.conversationId, action, params, signal);
const command = (action, params, signal) =>
  runIntention(
    [
      context.value.accountId,
      context.value.userId,
      props.conversationId,
      props.contact.id,
    ],
    action,
    params,
    key => api.command(props.conversationId, action, params, key, signal)
  );
function selectNegotiation(id) {
  selected.value = id;
  proposal.value = '';
  selectedReservation.value = relatedReservations.value[0]?.id || '';
  selectedQuote.value = relatedQuotes.value[0]?.id || '';
  selectedGroup.value =
    negotiation.value?.grupoId || negotiation.value?.grupoIds[0] || '';
  stage.value = negotiation.value?.tipo === 'orcamento' ? 'quote' : 'order';
}
async function refresh(signal) {
  context.value = await read('contexto', {}, signal);
  detail.value = context.value.clienteId
    ? await read('cliente_detalhe', {}, signal)
    : null;
  negotiations.value = context.value.clienteId
    ? (await read('resumo_comercial', {}, signal)).negociacoes
    : [];
  if (!negotiations.value.some(item => item.id === selected.value)) {
    selectNegotiation(negotiations.value[0]?.id || '');
    return;
  }
  if (!negotiation.value.grupoIds.includes(selectedGroup.value))
    selectedGroup.value =
      negotiation.value.grupoId || negotiation.value.grupoIds[0] || '';
  if (
    !relatedReservations.value.some(
      item => item.id === selectedReservation.value
    )
  )
    selectedReservation.value = relatedReservations.value[0]?.id || '';
  if (!relatedQuotes.value.some(item => item.id === selectedQuote.value))
    selectedQuote.value = relatedQuotes.value[0]?.id || '';
}
async function openNative(destino, signal, target = null) {
  const result = await command(
    'abrir_nativo',
    {
      dados: {
        destino,
        ...(target?.orcamentoId ? { orcamentoId: target.orcamentoId } : {}),
        ...(target?.reservaId ? { reservaId: target.reservaId } : {}),
        ...(target?.grupoId ? { grupoId: target.grupoId } : {}),
        ...(!target &&
        ['orcamento', 'orcamento_editar', 'orcamento_converter'].includes(
          destino
        ) &&
        negotiation.value?.orcamentoIds?.length
          ? {
              orcamentoId: (stage.value === 'quote'
                ? activeNegotiation.value
                : negotiation.value
              ).orcamentoIds[0],
            }
          : {}),
        ...(!target &&
        ['os', 'pagamento'].includes(destino) &&
        activeNegotiation.value?.grupoId
          ? { grupoId: activeNegotiation.value.grupoId }
          : {}),
        ...(!target &&
        ['reserva', 'pagamento'].includes(destino) &&
        activeNegotiation.value?.tipo === 'reserva'
          ? { reservaId: activeNegotiation.value.reservaIds[0] }
          : {}),
      },
    },
    signal
  );
  const url = new URL(result.url);
  if (
    result.mode === 'external' ||
    url.origin !== result.origin ||
    url.protocol !== 'https:' ||
    !result.channel
  ) {
    error.value = t('VIARI.NATIVE_UNAVAILABLE');
    return;
  }
  session.value = result;
}
async function closeNative() {
  session.value = null;
  await run(refresh);
}
async function find(signal) {
  candidates.value = (await read('cliente_buscar', {}, signal)).clientes;
}
async function savedNative() {
  session.value = null;
  await run(async signal => {
    await refresh(signal);
    if (!context.value.clienteId) {
      linking.value = true;
      await find(signal);
    }
  });
}
async function navigateNative(event) {
  const destinations = [
    'orcamento_converter',
    'orcamento_editar',
    'pagamento',
    'cliente_editar',
    'os',
    'reserva',
  ];
  if (!destinations.includes(event.destino)) return;
  await run(signal => openNative(event.destino, signal, event));
}
async function link(customer, signal) {
  await command('cliente_vincular', { clienteId: customer.id }, signal);
  linking.value = false;
  await refresh(signal);
}
async function prepare(signal) {
  const orcamentoId = activeNegotiation.value.orcamentoIds[0];
  const response = await read('orcamento', { orcamentoId }, signal);
  const quote = response.orcamento || response;
  const result = await command(
    'orcamento_enviar',
    {
      orcamentoId,
      dados: { revisao: quote.revisao || quote.atualizadoEm },
    },
    signal
  );
  proposal.value = result.textoWhatsapp || '';
}
onMounted(() => run(refresh));
</script>

<template>
  <section
    class="flex min-w-0 flex-col gap-3 text-sm"
    :aria-busy="request.isPending.value"
  >
    <p v-if="error" role="alert" class="m-0 text-n-ruby-9">{{ error }}</p>
    <p v-if="request.isPending.value" role="status" class="m-0">
      {{ t('VIARI.LOADING') }}
    </p>
    <template v-if="context && !context.clienteId">
      <p class="m-0">{{ t('VIARI.LINK_REQUIRED') }}</p>
      <button
        type="button"
        class="text-start text-n-brand"
        @click="
          linking = true;
          run(find);
        "
      >
        {{ t('VIARI.SEARCH') }}
      </button>
      <button
        v-if="can('cliente_criar')"
        type="button"
        class="text-start text-n-brand"
        @click="run(signal => openNative('cliente_criar', signal))"
      >
        {{ t('VIARI.NEW_CUSTOMER') }}
      </button>
    </template>
    <template v-if="detail">
      <header class="flex items-center justify-between gap-2">
        <strong class="truncate">{{ detail.cliente.nome }}</strong>
        <button
          v-if="can('cliente_editar')"
          type="button"
          class="text-n-brand"
          @click="run(signal => openNative('cliente', signal))"
        >
          {{ t('VIARI.EDIT') }}
        </button>
      </header>
      <label class="flex flex-col gap-1">
        <span class="text-xs text-n-slate-11">{{
          t('VIARI.NEGOTIATION')
        }}</span>
        <select
          :value="selected"
          class="w-full min-w-0"
          @change="selectNegotiation($event.target.value)"
        >
          <option v-if="!negotiations.length" value="">
            {{ t('VIARI.NO_QUOTES') }}
          </option>
          <option v-for="item in negotiations" :key="item.id" :value="item.id">
            {{ item.codigo || item.id }} ·
            {{ item.status || date(item.passeios[0]?.data) }}
          </option>
        </select>
      </label>
      <button
        v-if="can('orcamento_criar')"
        type="button"
        class="text-start text-n-brand"
        @click="run(signal => openNative('orcamento_novo', signal))"
      >
        {{ t('VIARI.QUOTE') }}
      </button>
      <button
        v-if="can('reserva_criar')"
        type="button"
        class="text-start text-n-brand"
        @click="run(signal => openNative('reserva_criar', signal))"
      >
        {{ t('VIARI.NEW_ORDER') }}
      </button>
      <template v-if="negotiation">
        <nav class="flex gap-2" :aria-label="t('VIARI.STAGES')">
          <button
            type="button"
            :disabled="!negotiation.orcamentoIds.length"
            :aria-current="stage === 'quote' ? 'step' : undefined"
            class="text-n-brand"
            @click="stage = 'quote'"
          >
            {{ t('VIARI.QUOTE_STAGE') }}
          </button>
          <span aria-hidden="true" class="i-lucide-chevron-right size-4" />
          <button
            type="button"
            :disabled="
              !negotiation.grupoIds.length && !negotiation.reservaIds.length
            "
            :aria-current="stage === 'order' ? 'step' : undefined"
            class="text-n-brand disabled:opacity-50"
            @click="stage = 'order'"
          >
            {{ t('VIARI.ORDER') }}
          </button>
          <span aria-hidden="true" class="i-lucide-chevron-right size-4" />
          <button
            type="button"
            :disabled="
              !negotiation.grupoIds.length && !negotiation.reservaIds.length
            "
            :aria-current="stage === 'payment' ? 'step' : undefined"
            class="text-n-brand disabled:opacity-50"
            @click="stage = 'payment'"
          >
            {{ t('VIARI.PAYMENT_STAGE') }}
          </button>
        </nav>
        <select
          v-if="stage !== 'quote' && negotiation.grupoIds.length > 1"
          v-model="selectedGroup"
          :aria-label="t('VIARI.ORDER')"
        >
          <option v-for="id in negotiation.grupoIds" :key="id" :value="id">
            {{
              negotiations.find(
                item => item.tipo === 'os' && item.grupoId === id
              )?.codigo || id
            }}
          </option>
        </select>
        <select
          v-if="stage === 'quote' && relatedQuotes.length > 1"
          v-model="selectedQuote"
          :aria-label="t('VIARI.QUOTE_STAGE')"
        >
          <option v-for="item in relatedQuotes" :key="item.id" :value="item.id">
            {{ item.codigo || item.id }}
          </option>
        </select>
        <select
          v-if="
            stage !== 'quote' &&
            !negotiation.grupoIds.length &&
            relatedReservations.length > 1
          "
          v-model="selectedReservation"
          :aria-label="t('VIARI.ORDER')"
        >
          <option
            v-for="item in relatedReservations"
            :key="item.id"
            :value="item.id"
          >
            {{ item.codigo || item.id }}
          </option>
        </select>
        <ol
          v-if="stage !== 'payment'"
          class="m-0 flex list-none flex-col gap-2 p-0"
        >
          <li
            v-for="item in items"
            :key="item.id"
            class="rounded-lg border border-n-weak p-2"
          >
            <p class="m-0 font-medium">
              {{
                item.produtoNome ||
                item.produto?.nome ||
                item.agenda?.produto?.nome ||
                item.nome
              }}
            </p>
            <p class="m-0 text-xs text-n-slate-11">
              {{ date(item.data) }}
            </p>
            <p class="m-0 text-xs">
              {{
                pax
                  .map(
                    type => type.toUpperCase() + ' ' + (item['qtd' + type] ?? 0)
                  )
                  .join(' · ')
              }}
            </p>
            <p class="m-0 text-xs">
              {{ t('VIARI.PAX') }}
              {{ item.totalPax }}
            </p>
            <p class="m-0 text-end">
              {{ item.horario || '' }}
            </p>
          </li>
        </ol>
        <dl class="m-0 grid grid-cols-2 gap-1 rounded-lg bg-n-alpha-2 p-2">
          <dt>{{ t('VIARI.TOTAL') }}</dt>
          <dd class="m-0 text-end">
            {{ money(totals?.total) }}
          </dd>
          <dt>{{ t('VIARI.NORMAL_TOTAL') }}</dt>
          <dd class="m-0 text-end">{{ money(totals?.totalNormal) }}</dd>
          <dt>{{ t('VIARI.PIX_TOTAL') }}</dt>
          <dd class="m-0 text-end">{{ money(totals?.totalPix) }}</dd>
          <dt>{{ t('VIARI.TOTAL_PAID') }}</dt>
          <dd class="m-0 text-end">{{ money(totals?.pago) }}</dd>
          <dt>{{ t('VIARI.BALANCE') }}</dt>
          <dd class="m-0 text-end">{{ money(totals?.saldo) }}</dd>
        </dl>
        <button
          type="button"
          class="text-start text-n-brand"
          @click="
            run(signal =>
              openNative(
                stage === 'quote'
                  ? 'orcamento'
                  : stage === 'payment'
                    ? 'pagamento'
                    : activeNegotiation.tipo === 'reserva'
                      ? 'reserva'
                      : 'os',
                signal
              )
            )
          "
        >
          {{ t('VIARI.OPEN_NATIVE') }}
        </button>
        <button
          v-if="
            stage === 'quote' &&
            negotiation.orcamentoIds.length &&
            can('orcamento_enviar')
          "
          type="button"
          class="text-start text-n-brand"
          @click="run(prepare)"
        >
          {{ t('VIARI.PREPARE') }}
        </button>
        <button
          v-if="proposal"
          type="button"
          class="text-start text-n-brand"
          @click="emitter.emit(BUS_EVENTS.INSERT_INTO_RICH_EDITOR, proposal)"
        >
          {{ t('VIARI.COMPOSER') }}
        </button>
      </template>
    </template>
    <button type="button" class="text-start text-n-brand" @click="run(refresh)">
      {{ t('VIARI.REFRESH') }}
    </button>
    <dialog
      ref="linkingDialog"
      class="fixed inset-0 z-50 rounded-xl border border-n-weak bg-n-background p-4"
      :aria-label="t('VIARI.SEARCH')"
      @cancel.prevent="linking = false"
    >
      <div class="flex flex-col gap-3">
        <p v-if="candidates && !candidates.length" class="m-0">
          {{ t('VIARI.NO_MATCH') }}
        </p>
        <button
          v-for="candidate in can('cliente_vincular') ? candidates : []"
          :key="candidate.id"
          type="button"
          class="text-start text-n-brand"
          @click="run(signal => link(candidate, signal))"
        >
          {{ t('VIARI.LINK') }} · {{ candidate.nome }} ·
          {{ candidate.telefone }}
        </button>
        <button type="button" @click="linking = false">
          {{ t('VIARI.CLOSE') }}
        </button>
      </div>
    </dialog>
    <NativeModal
      v-if="session"
      :session="session"
      @saved="savedNative"
      @navigate="navigateNative"
      @refresh="run(refresh)"
      @close="closeNative"
    />
  </section>
</template>
