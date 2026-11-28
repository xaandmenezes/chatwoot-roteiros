<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import api from 'dashboard/api/integrations/viari';
import QuoteForm from './ViariQuoteForm.vue';
import PaymentForm from './ViariPaymentForm.vue';
import { acknowledgePending, runIntention } from './intention';
import OrderActions from './ViariOrderActions.vue';
import QuoteEditor from './ViariQuoteEditor.vue';
import PartnerForm from './ViariPartnerForm.vue';

const props = defineProps({
  conversationId: { type: Number, required: true },
  contact: { type: Object, required: true },
});
const { t } = useI18n();
const controller = new AbortController();
const linked = ref(null);
const detail = ref(null);
const quote = ref(null);
const order = ref(null);
const candidates = ref([]);
const lookupComplete = ref(false);
const searched = ref(false);
const identity = ref(null);
const rights = ref([]);
const pendingAction = ref('');
const reviewedHistory = ref(false);
const can = action => rights.value.includes(action);
const customerEdit = ref(null);
const customerData = ref({});
const approved = ref(false);
const conversion = ref({ locaisEmbarque: {} });
const reason = ref('');
const offerLinks = ref({});
const customerFields = [
  'email',
  'documento',
  'nacionalidade',
  'hotelHospedado',
  'dataChegada',
  'dataPartida',
  'observacoes',
];
const name = ref(props.contact.name || '');
const phone = ref(props.contact.phone_number || '');
const tab = ref('history');
const catalog = ref(null);
const partners = ref([]);
const error = ref('');
const busy = ref(false);
const proposal = ref('');

const quotes = computed(() => detail.value?.orcamentos || []);
const read = (action, params = {}, signal = controller.signal) =>
  api.read(props.conversationId, action, params, signal);
async function refresh() {
  const context = await read('contexto');
  rights.value = context.acoes;
  linked.value = context.clienteId;
  identity.value = [
    context.accountId,
    context.userId,
    props.conversationId,
    props.contact.id,
  ];
  if (linked.value) detail.value = await read('cliente_detalhe');
  if (!catalog.value && can('catalogo')) catalog.value = await read('catalogo');
}
async function command(action, params) {
  if (!identity.value) throw new Error('No conversation context');
  try {
    return await runIntention(identity.value, action, params, key =>
      api.command(props.conversationId, action, params, key, controller.signal)
    );
  } catch (e) {
    if (e.code === 'VIARI_PENDING') {
      pendingAction.value = action;
      reviewedHistory.value = false;
      await refresh();
      tab.value = 'history';
    }
    throw e;
  }
}
async function run(operation) {
  if (busy.value) return;
  busy.value = true;
  error.value = '';
  try {
    await operation();
  } catch (e) {
    if (!controller.signal.aborted)
      error.value = e.response?.data?.error?.mensagem || t('VIARI.ERROR');
  } finally {
    busy.value = false;
  }
}
async function find() {
  const result = await read('cliente_buscar');
  candidates.value = result.clientes;
  lookupComplete.value = true;

  searched.value = true;
}
async function link(customer) {
  await command('cliente_vincular', { clienteId: customer.id });
  await refresh();
}
async function createCustomer() {
  await command('cliente_criar', {
    dados: {
      ...Object.fromEntries(
        Object.entries(customerData.value).filter(([, v]) => v)
      ),
      nome: name.value.trim(),
      telefone: phone.value.trim(),
    },
  });
  await refresh();
}
async function openTab(target) {
  if (target === 'quote' && !catalog.value)
    catalog.value = await read('catalogo');
  if (target === 'partner')
    partners.value = (
      await read('parceiros', { incluirInativos: can('parceiro_editar') })
    ).parceiros;
  tab.value = target;
}
async function selectQuote(item) {
  const result = await read('orcamento', { orcamentoId: item.id });
  if (!catalog.value && can('catalogo')) catalog.value = await read('catalogo');
  quote.value = result.orcamento || result;
  approved.value = false;
  conversion.value = { locaisEmbarque: {} };
  reason.value = '';
  offerLinks.value = {};
  order.value = null;
  proposal.value = '';
  tab.value = 'history';
}
async function saveQuote(dados) {
  const result = await command('orcamento_criar', { dados });
  await refresh();
  await selectQuote(result);
}
async function selectOrder(grupoId) {
  const result = await read('os', { grupoId });
  order.value = { ...result, grupoId };
  partners.value = catalog.value?.parceirosRecebedores || [];
  if (!catalog.value && can('catalogo')) catalog.value = await read('catalogo');
  tab.value = 'payment';
}
async function transition(action, fields = {}) {
  const dados = {
    ...fields,
    revisao: quote.value.revisao || quote.value.atualizadoEm,
  };
  const result = await command(action, { orcamentoId: quote.value.id, dados });
  await refresh();
  await selectQuote(quote.value);
  if (action === 'orcamento_enviar') {
    proposal.value = result.textoWhatsapp || '';
    offerLinks.value = result;
  }
  if (action === 'orcamento_converter') await selectOrder(result.grupoId);
}
onMounted(() => run(refresh));
onBeforeUnmount(() => controller.abort());
</script>

<template>
  <section
    class="flex flex-col gap-2 [&_label]:grid [&_label]:gap-1 [&_input]:min-w-0 [&_select]:min-w-0 [&_button]:text-n-brand [&_button]:text-start [&_button:disabled]:opacity-50"
    :aria-busy="busy"
  >
    <fieldset v-if="pendingAction">
      <p role="alert">{{ t('VIARI.PENDING') }}</p>
      <label
        ><input v-model="reviewedHistory" type="checkbox" />{{
          t('VIARI.RECONCILED')
        }}</label
      >
      <button
        :disabled="!reviewedHistory"
        @click="
          acknowledgePending(identity, pendingAction);
          pendingAction = '';
        "
      >
        {{ t('VIARI.NEW_INTENT') }}
      </button>
    </fieldset>
    <p v-if="error" role="alert">{{ error }}</p>
    <button v-if="error" @click="run(refresh)">{{ t('VIARI.REFRESH') }}</button>
    <p v-if="busy" role="status">{{ t('VIARI.LOADING') }}</p>
    <fieldset :disabled="busy" class="flex min-w-0 flex-col gap-2">
      <template v-if="!linked">
        <button v-if="can('parceiros')" @click="run(() => openTab('partner'))">
          {{ t('VIARI.PARTNER') }}
        </button>
        <button :disabled="!identity" @click="run(find)">
          {{ t('VIARI.SEARCH') }}
        </button>
        <button
          v-if="can('cliente_criar') && !searched"
          @click="searched = true"
        >
          {{ t('VIARI.NEW_CUSTOMER') }}
        </button>
        <template v-if="searched">
          <p v-if="lookupComplete && !candidates.length">
            {{ t('VIARI.NO_MATCH') }}
          </p>
          <button
            v-for="candidate in can('cliente_vincular') ? candidates : []"
            :key="candidate.id"
            @click="run(() => link(candidate))"
          >
            {{ t('VIARI.LINK') }} · {{ candidate.nome }} ·
            {{ candidate.telefone }}
          </button>
          <template v-if="can('cliente_criar')">
            <label>
              <span>{{ t('VIARI.NAME') }}</span>
              <input v-model.trim="name" />
            </label>
            <label>
              <span>{{ t('VIARI.PHONE') }}</span>
              <input v-model.trim="phone" type="tel" />
            </label>
            <details>
              <summary>{{ t('VIARI.DETAILS') }}</summary>
              <label v-for="f in customerFields" :key="f">
                <span>{{ t('VIARI.' + f) }}</span>
                <input
                  v-model.trim="customerData[f]"
                  :type="f.startsWith('data') ? 'date' : 'text'"
                />
              </label>
            </details>
            <label v-if="catalog?.canaisAquisicao?.length">
              <span>{{ t('VIARI.ACQUISITION') }}</span>
              <select v-model="customerData.canalAquisicaoId">
                <option value="">—</option>
                <option
                  v-for="c in catalog.canaisAquisicao"
                  :key="c.id"
                  :value="c.id"
                >
                  {{ c.nome }}
                </option>
              </select>
            </label>
            <button :disabled="!name.trim()" @click="run(createCustomer)">
              {{ t('VIARI.CONFIRM_CUSTOMER') }}
            </button>
          </template>
        </template>
      </template>
      <template v-else-if="detail">
        <strong>{{ detail.cliente.nome }}</strong>
        <button
          v-if="can('cliente_editar')"
          @click="
            customerEdit = {
              ...Object.fromEntries(
                ['nome', 'telefone', 'canalAquisicaoId', ...customerFields].map(
                  k => [
                    k,
                    k.startsWith('data')
                      ? detail.cliente[k]?.slice(0, 10) || ''
                      : detail.cliente[k] || '',
                  ]
                )
              ),
            }
          "
        >
          {{ t('VIARI.EDIT_CUSTOMER') }}
        </button>
        <form
          v-if="customerEdit"
          @submit.prevent="
            run(async () => {
              const dados = Object.fromEntries(
                Object.entries(customerEdit).filter(([, v]) => v !== '')
              );
              await command('cliente_editar', { dados });
              customerEdit = null;
              await refresh();
            })
          "
        >
          <label
            v-for="key in ['nome', 'telefone', ...customerFields]"
            :key="key"
          >
            <span>{{
              key === 'nome' ? t('VIARI.NAME') : t('VIARI.' + key)
            }}</span>
            <input
              v-model="customerEdit[key]"
              :type="key.startsWith('data') ? 'date' : 'text'"
              :required="key === 'nome'"
            />
          </label>
          <label v-if="catalog?.canaisAquisicao?.length">
            <span>{{ t('VIARI.ACQUISITION') }}</span>
            <select v-model="customerEdit.canalAquisicaoId">
              <option value="">—</option>
              <option
                v-for="c in catalog.canaisAquisicao"
                :key="c.id"
                :value="c.id"
              >
                {{ c.nome }}
              </option>
            </select>
          </label>
          <button>{{ t('VIARI.SAVE') }}</button>
        </form>
        <nav class="flex flex-wrap gap-1">
          <button
            v-for="section in [
              'history',
              ...(can('orcamento_criar') ? ['quote'] : []),
              ...(can('parceiros') ? ['partner'] : []),
            ]"
            :key="section"
            @click="run(() => openTab(section))"
          >
            {{ t('VIARI.' + section.toUpperCase()) }}
          </button>
        </nav>
        <template v-if="tab === 'history'">
          <button @click="run(refresh)">{{ t('VIARI.REFRESH') }}</button>
          <button
            v-for="item in quotes"
            :key="item.id"
            @click="run(() => selectQuote(item))"
          >
            {{ item.codigo }} · {{ item.status }}
          </button>
          <template v-if="quote">
            <strong>{{ quote.codigo }} · {{ quote.status }}</strong>
            <p>
              {{ t('VIARI.TOTAL') }} {{ quote.valorTotal }} ·
              {{ t('VIARI.pix') }} {{ quote.valorTotalPix }}
            </p>
            <p v-for="item in quote.itens" :key="item.id">
              {{ item.produto?.nome || item.nome }} · {{ item.valorTotalItem }}
            </p>
            <QuoteEditor
              v-if="quote.status === 'rascunho' && can('orcamento_editar')"
              :key="quote.id + (quote.revisao || quote.atualizadoEm)"
              :quote="quote"
              :read="read"
              :catalog="catalog"
              @edit="
                fields => run(() => transition('orcamento_editar', fields))
              "
            />
            <button
              v-if="
                can('orcamento_enviar') &&
                ['rascunho', 'enviado', 'visualizado', 'aprovado'].includes(
                  quote.status
                )
              "
              @click="run(() => transition('orcamento_enviar'))"
            >
              {{ t('VIARI.PREPARE') }}
            </button>
            <button
              v-if="proposal"
              @click="
                emitter.emit(BUS_EVENTS.INSERT_INTO_RICH_EDITOR, proposal)
              "
            >
              {{ t('VIARI.COMPOSER') }}
            </button>
            <template
              v-if="
                can('orcamento_aprovar') &&
                ['rascunho', 'enviado', 'visualizado'].includes(quote.status)
              "
            >
              <label
                ><input v-model="approved" type="checkbox" />{{
                  t('VIARI.CONFIRM_APPROVAL')
                }}</label
              >
              <button
                :disabled="!approved"
                @click="
                  run(() =>
                    transition('orcamento_aprovar', { confirmado: true })
                  )
                "
              >
                {{ t('VIARI.APPROVE') }}
              </button>
              <label>
                <span>{{ t('VIARI.REASON') }}</span>
                <input v-model.trim="reason" />
              </label>
              <button
                :disabled="!reason"
                @click="
                  run(() => transition('orcamento_recusar', { motivo: reason }))
                "
              >
                {{ t('VIARI.REJECT') }}
              </button>
            </template>
            <template v-if="offerLinks.urlProposta">
              <a
                :href="offerLinks.urlProposta"
                target="_blank"
                rel="noopener noreferrer"
                >{{ t('VIARI.PREPARED') }}</a
              >
              <a
                :href="offerLinks.urlPdf"
                target="_blank"
                rel="noopener noreferrer"
                >{{ t('VIARI.PDF') }}</a
              >
            </template>
            <label
              v-if="can('orcamento_converter') && quote.status === 'aprovado'"
            >
              <span>{{ t('VIARI.CONVERT_NOTES') }}</span>
              <textarea v-model="conversion.observacoes" />
            </label>
            <template
              v-if="
                can('orcamento_converter') &&
                quote.status === 'aprovado' &&
                catalog?.locaisEmbarque?.length
              "
            >
              <label v-for="item in quote.itens" :key="item.id">
                <span>{{ t('VIARI.EMBARK') }} · {{ item.produto?.nome }}</span>
                <select
                  :value="conversion.locaisEmbarque[item.id] || ''"
                  @change="
                    $event.target.value
                      ? (conversion.locaisEmbarque[item.id] =
                          $event.target.value)
                      : delete conversion.locaisEmbarque[item.id]
                  "
                >
                  <option value="">—</option>
                  <option
                    v-for="e in catalog.locaisEmbarque"
                    :key="e.id"
                    :value="e.id"
                  >
                    {{ e.nome }}
                  </option>
                </select>
              </label>
            </template>
            <button
              v-if="can('orcamento_converter') && quote.status === 'aprovado'"
              @click="run(() => transition('orcamento_converter', conversion))"
            >
              {{ t('VIARI.CONVERT') }}
            </button>
          </template>
          <button
            v-for="reservation in detail.reservas.filter(
              r => r.grupoReservaId && r.orcamentoId
            )"
            :key="reservation.id"
            @click="run(() => selectOrder(reservation.grupoReservaId))"
          >
            {{ t('VIARI.ORDER') }} ·
            {{
              reservation.codigo || reservation.voucherCode || reservation.id
            }}
            · {{ reservation.status }}
          </button>
          <p v-for="payment in detail.pagamentos" :key="payment.id">
            {{ payment.tipoPagamento }} · {{ payment.valor }} ·
            {{ payment.status }}
          </p>
        </template>
        <QuoteForm
          v-if="tab === 'quote'"
          :catalog="catalog"
          :read="read"
          @save="data => run(() => saveQuote(data))"
        />
        <OrderActions
          v-if="tab === 'payment'"
          :key="order.grupoId"
          :order="order"
          :command="command"
          :read="read"
          :can="can"
          @changed="
            run(async () => {
              await refresh();
              await selectOrder(order.grupoId);
            })
          "
        />
        <PaymentForm
          v-if="tab === 'payment' && can('pagamento_registrar')"
          :key="order.grupoId"
          :accounts="catalog?.contasBancarias || []"
          :order="order"
          :partners="partners"
          :command="command"
          @paid="
            run(async () => {
              await refresh();
              await selectOrder(order.grupoId);
            })
          "
        />
      </template>
      <PartnerForm
        v-if="tab === 'partner'"
        :partners="partners"
        :can="can"
        @save="
          (action, dados) =>
            run(async () => {
              await command(action, { dados });
              await openTab('partner');
            })
        "
      />
    </fieldset>
  </section>
</template>
