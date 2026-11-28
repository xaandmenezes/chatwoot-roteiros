<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import PartialCancellation from './ViariPartialCancellation.vue';
import PassengerForm from './ViariPassengerForm.vue';
const props = defineProps({
  order: { type: Object, required: true },
  can: { type: Function, required: true },
  command: { type: Function, required: true },
  read: { type: Function, required: true },
});
const emit = defineEmits(['changed']);
const { t } = useI18n();
const selected = ref('');
const child = ref(null);
const reason = ref('');
const cancellation = ref(false);
const cancellationPreview = ref(null);
const schedule = ref('');
const schedules = ref([]);
const refundRetention = ref(false);
const retained = ref(0);
const updatingPassenger = ref(null);
const refund = ref(null);
const editing = ref(null);
const busy = ref(false);
const error = ref('');
const target = computed(() =>
  selected.value
    ? { reservaId: selected.value }
    : { grupoId: props.order.grupoId }
);
async function run(callback) {
  if (busy.value) return;
  busy.value = true;
  error.value = '';
  try {
    await callback();
  } catch (e) {
    error.value = e.response?.data?.error?.mensagem || t('VIARI.ERROR');
  } finally {
    busy.value = false;
  }
}
async function showReservation() {
  child.value = null;
  updatingPassenger.value = null;
  retained.value = 0;
  schedule.value = '';
  schedules.value = [];
  cancellationPreview.value = null;
  refundRetention.value = false;
  cancellation.value = false;
  refund.value = null;
  editing.value = null;
  if (selected.value)
    child.value = await props.read('reserva', { reservaId: selected.value });
}
async function write(action, dados, scope = target.value) {
  await props.command(action, { ...scope, dados });
  editing.value = null;
  refund.value = null;
  cancellation.value = false;
  await showReservation();
  emit('changed');
}
function paymentScope(payment) {
  return payment.grupoReservaId
    ? { grupoId: payment.grupoReservaId }
    : { reservaId: payment.reservaId };
}
async function prepareEdit(payment) {
  const scope = paymentScope(payment);
  const data = await props.command('pagamento_dados_edicao', {
    ...scope,
    dados: { pagamentoId: payment.id },
  });
  editing.value = { scope, data };
  refund.value = null;
}
async function saveEdit() {
  const { data, scope } = editing.value;
  const allowed = [
    'valor',
    'metodo',
    'tipoPagamento',
    'recebedorTipo',
    'parceiroId',
    'parcelas',
    'data',
    'contaBancariaId',
    'versao',
    'gatewayRef',
  ];
  const dados = Object.fromEntries(
    allowed
      .filter(k => data[k] != null && data[k] !== '')
      .map(k => [k, data[k]])
  );
  if (dados.recebedorTipo !== 'parceiro') delete dados.parceiroId;
  if (dados.metodo !== 'cartao_credito') dados.parcelas = 1;
  await write(
    'pagamento_editar',
    {
      ...dados,
      pagamentoId: data.id,
      contaBancariaAlterada:
        data.contaBancariaId !== editing.value.originalBank,
    },
    scope
  );
}
async function startRefund(payment) {
  const scope = paymentScope(payment);
  const preview = await props.command('pagamento_estorno_previa', {
    ...scope,
    dados: { pagamentoId: payment.id },
  });
  refund.value = { payment, scope, preview, valor: preview.valorDisponivel };
  editing.value = null;
}
</script>

<template>
  <fieldset class="grid gap-2" :disabled="busy">
    <label>
      <span>{{ t('VIARI.TARGET') }}</span>
      <select v-model="selected" @change="run(showReservation)">
        <option value="">{{ t('VIARI.ORDER') }} {{ order.codigo }}</option>
        <option v-for="r in order.reservas" :key="r.id" :value="r.id">
          {{ r.agenda.produto.nome }} · {{ r.voucherCode }} · {{ r.status }}
        </option>
      </select>
    </label>
    <PartialCancellation
      v-if="child && can('reserva_editar') && child.status === 'confirmada'"
      :key="child.id"
      :reservation="child"
      :command="command"
      @changed="
        run(async () => {
          await showReservation();
          emit('changed');
        })
      "
    />
    <div v-if="child">
      {{ child.agenda.produto.nome }} · {{ child.status }} ·
      {{ child.voucherCode }}
    </div>
    <details v-if="child && can('reserva_editar')">
      <summary>{{ t('VIARI.RESCHEDULE') }}</summary>
      <button
        @click="
          run(async () => {
            const result = await read('reserva_agendas_remarcacao', {
              reservaId: child.id,
            });
            if (result.error) throw new Error(result.error);
            schedules = result.agendas;
          })
        "
      >
        {{ t('VIARI.AVAILABILITY') }}
      </button>
      <label>
        <span>{{ t('VIARI.SCHEDULE') }}</span>
        <select v-model="schedule">
          <option value="">—</option>
          <option v-for="a in schedules" :key="a.id" :value="a.id">
            {{ a.data }} · {{ a.horario }} · {{ a.vagasDisponiveis }}
          </option>
        </select>
      </label>
      <button
        :disabled="!schedule || schedule === child.agenda.id"
        @click="
          run(() =>
            write('reserva_editar', {
              agendaId: schedule,
              agendaOriginalId: child.agenda.id,
            })
          )
        "
      >
        {{ t('VIARI.RESCHEDULE') }}
      </button>
    </details>
    <details>
      <summary>{{ t('VIARI.PASSENGERS') }}</summary>
      <PartialCancellation
        v-if="child && can('reserva_editar') && child.status === 'confirmada'"
        :key="child.id"
        :reservation="child"
        :command="command"
        @changed="
          run(async () => {
            await showReservation();
            emit('changed');
          })
        "
      />
      <div v-if="child">
        <div v-for="p in order.passageiros" :key="p.id">
          {{ p.nome }}
          <button
            v-if="
              child.atribuicoes.some(a => a.passageiroId === p.id) &&
              can('reserva_passageiro_desatribuir')
            "
            @click="
              run(() =>
                write('reserva_passageiro_desatribuir', { passageiroId: p.id })
              )
            "
          >
            {{ t('VIARI.UNASSIGN') }}
          </button>
          <button
            v-else-if="can('reserva_passageiro_atribuir')"
            @click="
              run(() =>
                write('reserva_passageiro_atribuir', { passageiroId: p.id })
              )
            "
          >
            {{ t('VIARI.ASSIGN') }}
          </button>
        </div>
      </div>
      <p v-for="p in (child || order).passageiros" :key="p.id">
        {{ p.nome }} · {{ p.tipoPax }}
        <button
          v-if="child && can('reserva_passageiro_editar')"
          @click="updatingPassenger = p"
        >
          {{ t('VIARI.EDIT') }}
        </button>
        <button
          v-if="child && can('reserva_passageiro_remover')"
          @click="
            run(() =>
              write('reserva_passageiro_remover', { passageiroId: p.id })
            )
          "
        >
          {{ t('VIARI.REMOVE') }}
        </button>
      </p>
      <PassengerForm
        v-if="updatingPassenger"
        :key="updatingPassenger.id"
        :initial="updatingPassenger"
        @save="
          dados =>
            run(() =>
              write('reserva_passageiro_editar', {
                passageiroId: updatingPassenger.id,
                ...dados,
              })
            )
        "
      />
      <PassengerForm
        v-if="
          can(
            selected
              ? 'reserva_passageiro_adicionar'
              : 'os_passageiro_adicionar'
          )
        "
        @save="
          dados =>
            run(() =>
              write(
                selected
                  ? 'reserva_passageiro_adicionar'
                  : 'os_passageiro_adicionar',
                dados
              )
            )
        "
      />
    </details>
    <details
      v-if="child && can('reserva_cancelar') && child.status !== 'cancelada'"
    >
      <summary>{{ t('VIARI.CANCEL_RES') }}</summary>
      <button
        @click="
          run(async () => {
            cancellationPreview = await command('reserva_cancelamento_previa', {
              ...target,
              dados: {},
            });
            retained = cancellationPreview.valorRetido;
          })
        "
      >
        {{ t('VIARI.PREVIEW') }}
      </button>
      <p v-if="cancellationPreview">
        {{ cancellationPreview.regraTitulo }} · {{ t('VIARI.TOTAL_PAID') }}
        {{ cancellationPreview.totalPagamentos }} · {{ t('VIARI.REFUND') }}
        {{ cancellationPreview.valorAEstornar }}
      </p>
      <label v-if="cancellationPreview"
        ><input v-model="refundRetention" type="checkbox" />{{
          t('VIARI.RETAIN')
        }}</label
      ><label v-if="refundRetention">
        <span>{{ t('VIARI.AMOUNT') }}</span>
        <input v-model.number="retained" type="number" step=".01" min="0" />
      </label>
      <label>
        <span>{{ t('VIARI.REASON') }}</span>
        <input v-model.trim="reason" />
      </label>
      <label
        ><input v-model="cancellation" type="checkbox" />{{
          t('VIARI.CONFIRM_CANCEL')
        }}</label
      >
      <button
        :disabled="!cancellationPreview || !cancellation || !reason"
        @click="
          run(() =>
            write('reserva_cancelar', {
              motivo: reason,
              ...(refundRetention
                ? {
                    reterPagamento: true,
                    valorRetidoEsperado: Number(child.valorPago),
                    valorRetido: retained,
                  }
                : {}),
            })
          )
        "
      >
        {{ t('VIARI.CANCEL_RES') }}
      </button>
    </details>
    <div v-for="p in order.pagamentos" :key="p.id">
      {{ p.tipoPagamento }} · {{ p.valor }} · {{ p.status }}
      <button
        v-if="can('pagamento_editar')"
        @click="
          run(async () => {
            await prepareEdit(p);
            editing.originalBank = editing.data.contaBancariaId;
          })
        "
      >
        {{ t('VIARI.EDIT_PAYMENT') }}
      </button>
      <button
        v-if="can('pagamento_estornar') && p.status === 'aprovado'"
        @click="run(() => startRefund(p))"
      >
        {{ t('VIARI.REFUND') }}
      </button>
    </div>
    <form v-if="editing" @submit.prevent="run(saveEdit)">
      <p v-if="editing.data.bloqueioFinanceiro">
        {{ editing.data.bloqueioFinanceiro }}
      </p>
      <label>
        <span>{{ t('VIARI.AMOUNT') }}</span>
        <input
          v-model.number="editing.data.valor"
          type="number"
          min=".01"
          step=".01"
          required
        />
      </label>
      <label>
        <span>{{ t('VIARI.METHOD') }}</span>
        <select v-model="editing.data.metodo">
          <option
            v-for="m in [
              'pix',
              'cartao_credito',
              'cartao_debito',
              'dinheiro',
              'boleto',
              'transferencia',
            ]"
            :key="m"
            :value="m"
          >
            {{ t('VIARI.' + m) }}
          </option>
        </select>
      </label>
      <label>
        <span>{{ t('VIARI.DATE') }}</span>
        <input v-model="editing.data.data" type="date" required />
      </label>
      <label v-if="editing.data.metodo === 'cartao_credito'">
        <span>{{ t('VIARI.INSTALLMENTS') }}</span>
        <input
          v-model.number="editing.data.parcelas"
          type="number"
          min="1"
          max="12"
          required
        />
      </label>
      <label>
        <span>{{ t('VIARI.BANK_SELECT') }}</span>
        <select v-model="editing.data.contaBancariaId">
          <option :value="null">—</option>
          <option
            v-for="a in editing.data.contasBancarias"
            :key="a.id"
            :value="a.id"
          >
            {{ a.nome }}
          </option>
        </select>
      </label>
      <button :disabled="!!editing.data.bloqueioFinanceiro">
        {{ t('VIARI.SAVE') }}
      </button>
    </form>
    <form
      v-if="refund"
      @submit.prevent="
        run(() =>
          write(
            'pagamento_estornar',
            {
              pagamentoId: refund.payment.id,
              valor: refund.valor,
              valorDisponivelEsperado: refund.preview.valorDisponivel,
            },
            refund.scope
          )
        )
      "
    >
      <p>{{ t('VIARI.BALANCE') }} {{ refund.preview.valorDisponivel }}</p>
      <label>
        <span>{{ t('VIARI.AMOUNT') }}</span>
        <input
          v-model.number="refund.valor"
          type="number"
          min=".01"
          :max="refund.preview.valorDisponivel"
          step=".01"
          required
        />
      </label>
      <button>{{ t('VIARI.CONFIRM_REFUND') }}</button>
    </form>
    <p v-if="error" role="alert">{{ error }}</p>
  </fieldset>
</template>
