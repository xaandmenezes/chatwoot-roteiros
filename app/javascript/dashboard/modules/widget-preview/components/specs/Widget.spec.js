import { shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';
import Widget from '../Widget.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const mountPreview = installationBranding =>
  shallowMount(Widget, {
    props: { websiteName: 'Web widget' },
    global: {
      plugins: [
        createStore({
          getters: {
            'globalConfig/get': () => ({
              installationName: 'Porto Seguro Roteiros',
              logoThumbnail: '/psr-logo.png',
            }),
            'globalConfig/installationBranding': () => installationBranding,
          },
        }),
      ],
      mocks: { $t: () => 'Powered by Chatwoot' },
    },
  });

describe('widget branding preview', () => {
  it('renders the same original name and logo as the public widget', () => {
    const wrapper = mountPreview({
      installationName: 'Original platform',
      brandName: 'Original brand',
      logoThumbnail: '/original-logo.png',
    });

    const logo = wrapper.get('img[src="/original-logo.png"]');
    expect(logo.attributes('alt')).toBe('Original brand');
    expect(wrapper.get('.widget-wrapper').text()).toContain(
      'Powered by Original platform'
    );
    expect(wrapper.find('img[src="/psr-logo.png"]').exists()).toBe(false);
  });

  it('hides the branding footer when the public brand name is empty', () => {
    const wrapper = mountPreview({
      installationName: 'Original platform',
      brandName: null,
      logoThumbnail: '/original-logo.png',
    });

    expect(wrapper.find('.widget-wrapper a').exists()).toBe(false);
  });
});
