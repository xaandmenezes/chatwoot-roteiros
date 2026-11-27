import { shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';

import Signup from './Index.vue';
import SignupForm from './components/Signup/Form.vue';
import Testimonials from './components/Testimonials/Index.vue';

const mountComponent = (props, isAChatwootInstance = true) =>
  shallowMount(Signup, {
    props,
    global: {
      plugins: [
        createStore({
          getters: {
            'globalConfig/get': () => ({
              installationName: 'Porto Seguro Roteiros',
              logo: '/logo.svg',
              logoDark: '/logo-dark.svg',
            }),
            'globalConfig/isAChatwootInstance': () => isAChatwootInstance,
          },
        }),
      ],
      mocks: {
        $t: key => {
          const translations = {
            'REGISTER.GET_STARTED': 'Get started with Chatwoot',
            'REGISTER.SHOPIFY.TITLE': 'Set up Chatwoot for your Shopify store',
            'REGISTER.SHOPIFY.DESCRIPTION':
              'Create your Chatwoot account to continue.',
          };
          return translations[key] || key;
        },
      },
      stubs: {
        RouterLink: {
          template: '<a><slot /></a>',
        },
      },
    },
  });

describe('Shopify signup', () => {
  it('passes the pending install token to the signup form', () => {
    const pendingInstallToken = 'a'.repeat(32);
    const wrapper = mountComponent({
      shopifyPendingInstall: pendingInstallToken,
    });

    expect(
      wrapper.findComponent(SignupForm).props('shopifyPendingInstall')
    ).toBe(pendingInstallToken);
    expect(wrapper.text()).toContain(
      'Set up Porto Seguro Roteiros for your Shopify store'
    );
    expect(wrapper.text()).toContain(
      'Create your Porto Seguro Roteiros account to continue.'
    );
    expect(wrapper.text()).not.toContain('Chatwoot');
    expect(wrapper.vm.loginRoute).toEqual({
      name: 'login',
      query: {
        redirect_url: `settings/integrations/shopify?shopify_pending_install=${pendingInstallToken}`,
      },
    });
    expect(wrapper.find('a').exists()).toBe(true);
  });

  it('preserves the regular signup experience without a token', () => {
    const wrapper = mountComponent({});

    expect(
      wrapper.findComponent(SignupForm).props('shopifyPendingInstall')
    ).toBe('');
    expect(wrapper.text()).toContain('Get started with Porto Seguro Roteiros');
    expect(wrapper.findComponent(Testimonials).exists()).toBe(true);
    expect(wrapper.find('a').exists()).toBe(true);
  });

  it('keeps the custom-installation signup layout when configured', () => {
    const wrapper = mountComponent({}, false);

    expect(wrapper.text()).toContain('REGISTER.TRY_WOOT');
    expect(wrapper.findComponent(Testimonials).exists()).toBe(false);
  });
});
