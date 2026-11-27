import { shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';
import SenderNameExamplePreview from '../SenderNameExamplePreview.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const mountPreview = props =>
  shallowMount(SenderNameExamplePreview, {
    props,
    global: {
      plugins: [
        createStore({
          getters: {
            'globalConfig/get': () => ({
              installationName: 'Porto Seguro Roteiros',
            }),
            'globalConfig/installationBranding': () => ({
              installationName: 'Original platform',
            }),
          },
        }),
      ],
      renderStubDefaultSlot: true,
    },
  });

describe('sender name example', () => {
  it('keeps the original example name for an unconfigured inbox', () => {
    const preview = mountPreview({});

    expect(preview.text()).toContain('Original platform');
    expect(preview.text()).not.toContain('Porto Seguro Roteiros');
  });

  it('shows the configured inbox business name', () => {
    const preview = mountPreview({ businessName: 'Business inbox' });

    expect(preview.text()).toContain('Business inbox');
    expect(preview.text()).not.toContain('Original platform');
  });
});
