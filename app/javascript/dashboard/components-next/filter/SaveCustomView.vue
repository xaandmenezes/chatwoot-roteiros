<script>
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import { CONTACTS_EVENTS } from 'dashboard/helper/AnalyticsHelper/events';
import { vOnClickOutside } from '@vueuse/components';
import { useTrack } from 'dashboard/composables';
import Checkbox from 'next/checkbox/Checkbox.vue';
import NextButton from 'next/button/Button.vue';
import NextInput from 'dashboard/components-next/input/Input.vue';

export default {
  components: {
    Checkbox,
    NextButton,
    NextInput,
  },
  directives: {
    onClickOutside: vOnClickOutside,
  },
  props: {
    canShare: { type: Boolean, default: false },
    filterType: {
      type: Number,
      default: 0,
    },
    customViewsQuery: {
      type: Object,
      default: () => {},
    },
    openLastSavedItem: {
      type: Function,
      default: () => {},
    },
  },
  emits: ['close'],
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      shareWithTeam: false,
      name: '',
    };
  },

  computed: {
    isButtonDisabled() {
      return this.v$.name.$invalid;
    },
  },

  validations: {
    name: {
      required,
      minLength: minLength(1),
    },
  },

  methods: {
    onClose() {
      this.$emit('close');
    },
    async saveCustomViews() {
      this.v$.$touch();
      if (this.v$.$invalid) {
        return;
      }
      try {
        await this.$store.dispatch('customViews/create', {
          name: this.name,
          filter_type: this.filterType,
          query: this.customViewsQuery,
          ...(this.canShare && this.filterType === 0 && this.shareWithTeam
            ? { visibility: 'team' }
            : {}),
        });
        this.alertMessage =
          this.filterType === 0
            ? this.$t('FILTER.CUSTOM_VIEWS.ADD.API_FOLDERS.SUCCESS_MESSAGE')
            : this.$t('FILTER.CUSTOM_VIEWS.ADD.API_SEGMENTS.SUCCESS_MESSAGE');
        this.onClose();

        useTrack(CONTACTS_EVENTS.SAVE_FILTER, {
          type: this.filterType === 0 ? 'folder' : 'segment',
        });
        this.openLastSavedItem();
      } catch (error) {
        this.alertMessage =
          error?.message ||
          (this.filterType === 0
            ? this.$t('FILTER.CUSTOM_VIEWS.ADD.API_FOLDERS.ERROR_MESSAGE')
            : this.$t('FILTER.CUSTOM_VIEWS.ADD.API_SEGMENTS.ERROR_MESSAGE'));
      } finally {
        useAlert(this.alertMessage);
      }
    },
  },
};
</script>

<template>
  <div
    v-on-click-outside="[
      () => $emit('close'),
      { ignore: ['#saveFilterTeleportTarget'] },
    ]"
    class="z-40 max-w-3xl lg:w-[500px] overflow-visible w-full border border-n-weak bg-n-alpha-3 backdrop-blur-[100px] shadow-lg rounded-xl p-6 grid gap-6"
  >
    <h3 class="text-base font-medium leading-6 text-n-slate-12">
      {{ $t('FILTER.CUSTOM_VIEWS.ADD.TITLE') }}
    </h3>
    <form class="w-full grid gap-6" @submit.prevent="saveCustomViews">
      <NextInput
        v-model="name"
        :placeholder="$t('FILTER.CUSTOM_VIEWS.ADD.PLACEHOLDER')"
        :message="
          v$.name.$error ? $t('FILTER.CUSTOM_VIEWS.ADD.ERROR_MESSAGE') : ''
        "
        :message-type="v$.name.$error ? 'error' : 'info'"
        @blur="v$.name.$touch"
      />
      <label
        v-if="canShare && filterType === 0"
        class="flex items-center gap-2 text-sm text-n-slate-12"
      >
        <Checkbox v-model="shareWithTeam" />
        {{ $t('FILTER.CUSTOM_VIEWS.ADD.SHARE_WITH_TEAM') }}
      </label>
      <div class="flex flex-row justify-end w-full gap-2">
        <NextButton faded slate sm @click.prevent="onClose">
          {{ $t('FILTER.CUSTOM_VIEWS.ADD.CANCEL_BUTTON') }}
        </NextButton>
        <NextButton solid blue sm :disabled="isButtonDisabled">
          {{ $t('FILTER.CUSTOM_VIEWS.ADD.SAVE_BUTTON') }}
        </NextButton>
      </div>
    </form>
  </div>
</template>
