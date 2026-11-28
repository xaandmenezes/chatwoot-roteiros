<script setup>
import { ref } from 'vue';
import { useI18n } from 'vue-i18n';
const props = defineProps({
  partners: { type: Array, required: true },
  can: { type: Function, required: true },
});
const emit = defineEmits(['save']);
const { t } = useI18n();
const blank = () => ({
  nome: '',
  tipo: 'agencia',
  contato: '',
  telefone: '',
  email: '',
  comissaoPercent: null,
  observacoes: '',
});
const form = ref(blank());
const id = ref('');
const types = [
  'transporte',
  'hospedagem',
  'guia',
  'restaurante',
  'operador',
  'agencia',
  'fornecedor',
];
function select(partner) {
  id.value = partner?.id || '';
  form.value = blank();
  if (partner)
    Object.keys(form.value).forEach(k => {
      if (partner[k] != null) form.value[k] = partner[k];
    });
}
function save() {
  const dados = Object.fromEntries(
    Object.entries(form.value).filter(([, v]) => v !== '' && v != null)
  );
  if (id.value) dados.parceiroId = id.value;
  emit('save', id.value ? 'parceiro_editar' : 'parceiro_criar', dados);
}
</script>

<template>
  <div class="grid gap-2">
    <div v-for="p in props.partners" :key="p.id">
      {{ p.nome }} · {{ p.tipo }}
      <span v-if="!p.ativo">{{ t('VIARI.INACTIVE') }}</span>
      <button v-if="can('parceiro_editar')" @click="select(p)">
        {{ t('VIARI.EDIT') }}
      </button>
      <button
        v-if="can('parceiro_ativar')"
        @click="
          emit('save', 'parceiro_ativar', { parceiroId: p.id, ativo: !p.ativo })
        "
      >
        {{ t(p.ativo ? 'VIARI.DEACTIVATE' : 'VIARI.ACTIVATE') }}
      </button>
    </div>
    <button v-if="id && can('parceiro_criar')" @click="select(null)">
      {{ t('VIARI.CREATE_PARTNER') }}
    </button>
    <form
      v-if="id ? can('parceiro_editar') : can('parceiro_criar')"
      class="grid gap-2"
      @submit.prevent="save"
    >
      <label>
        <span>{{ t('VIARI.NAME') }}</span>
        <input v-model.trim="form.nome" required minlength="2" />
      </label>
      <label>
        <span>{{ t('VIARI.TYPE') }}</span>
        <select v-model="form.tipo">
          <option v-for="x in types" :key="x">{{ x }}</option>
        </select>
      </label>
      <label
        v-for="f in ['contato', 'telefone', 'email', 'observacoes']"
        :key="f"
      >
        <span>{{ t('VIARI.' + f) }}</span>
        <input
          v-model.trim="form[f]"
          :type="f === 'email' ? 'email' : 'text'"
        />
      </label>
      <label>
        <span>{{ t('VIARI.COMMISSION') }}</span>
        <input
          v-model.number="form.comissaoPercent"
          type="number"
          min="0"
          max="100"
          step=".01"
        />
      </label>
      <button>{{ t(id ? 'VIARI.SAVE' : 'VIARI.CREATE_PARTNER') }}</button>
    </form>
  </div>
</template>
