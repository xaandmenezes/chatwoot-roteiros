<script setup>
import { ref } from 'vue';
import { useI18n } from 'vue-i18n';
const props = defineProps({ initial: { type: Object, default: null } });
const emit = defineEmits(['save']);
const { t } = useI18n();
const passenger = ref({
  nome: '',
  tipoPax: 'ADT',
  idade: null,
  documento: '',
  necessidadeEspecial: false,
  observacao: '',
});
if (props.initial)
  Object.keys(passenger.value).forEach(k => {
    if (props.initial[k] != null) passenger.value[k] = props.initial[k];
  });
const submit = () =>
  emit(
    'save',
    Object.fromEntries(
      Object.entries(passenger.value).filter(([, v]) => v !== '' && v != null)
    )
  );
</script>

<template>
  <form @submit.prevent="submit">
    <label>
      <span>{{ t('VIARI.NAME') }}</span>
      <input v-model.trim="passenger.nome" required minlength="2" />
    </label>
    <label>
      <span>{{ t('VIARI.TYPE') }}</span>
      <select v-model="passenger.tipoPax">
        <option v-for="p in ['ADT', 'CHD', 'INF', 'SEN', 'FREE']" :key="p">
          {{ p }}
        </option>
      </select>
    </label>
    <label>
      <span>{{ t('VIARI.AGE') }}</span>
      <input v-model.number="passenger.idade" type="number" min="0" max="130" />
    </label>
    <label>
      <span>{{ t('VIARI.documento') }}</span>
      <input v-model.trim="passenger.documento" />
    </label>
    <label
      ><input v-model="passenger.necessidadeEspecial" type="checkbox" />{{
        t('VIARI.SPECIAL')
      }}</label
    >
    <label>
      <span>{{ t('VIARI.observacoes') }}</span>
      <input v-model.trim="passenger.observacao" />
    </label>
    <button>{{ t(initial ? 'VIARI.SAVE' : 'VIARI.ADD_PASSENGER') }}</button>
  </form>
</template>
