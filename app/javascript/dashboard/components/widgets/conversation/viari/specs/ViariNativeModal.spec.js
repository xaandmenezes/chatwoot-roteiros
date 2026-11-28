import { mount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import { describe, expect, it, vi } from 'vitest';
import en from 'dashboard/i18n/locale/en/viari.json';
import Modal from '../ViariNativeModal.vue';

describe('Viari native workspace', () => {
  it('accepts lifecycle events only from its frame, origin and channel', async () => {
    HTMLDialogElement.prototype.showModal = vi.fn();
    const wrapper = mount(Modal, {
      attachTo: document.body,
      props: {
        session: {
          url: 'https://viari.example/atendimento/nativo',
          origin: 'https://viari.example',
          channel: 'session-1',
        },
      },
      global: {
        plugins: [
          createI18n({ legacy: false, locale: 'en', messages: { en } }),
        ],
      },
    });
    const frame = document.querySelector('iframe');
    const send = (overrides = {}) =>
      window.dispatchEvent(
        new MessageEvent('message', {
          origin: 'https://viari.example',
          source: frame.contentWindow,
          data: { type: 'viari:saved', channel: 'session-1' },
          ...overrides,
        })
      );
    send({ origin: 'https://attacker.example' });
    send({ source: window });
    send({ data: { type: 'viari:saved', channel: 'other-session' } });
    expect(wrapper.emitted('saved')).toBeUndefined();
    send();
    expect(wrapper.emitted('saved')).toHaveLength(1);
    send({ data: { type: 'viari:refresh', channel: 'session-1' } });
    expect(wrapper.emitted('refresh')).toHaveLength(1);
    send({
      data: {
        type: 'viari:navigate',
        channel: 'session-1',
        destino: 'os',
        grupoId: '2',
      },
    });
    expect(wrapper.emitted('navigate')[0][0]).toMatchObject({
      destino: 'os',
      grupoId: '2',
    });
    send({ data: { type: 'viari:close', channel: 'session-1' } });
    expect(wrapper.emitted('close')).toHaveLength(1);
    expect(frame.getAttribute('sandbox')).not.toContain('allow-top-navigation');
    expect(frame.getAttribute('sandbox')).not.toContain('allow-popups');
    expect(frame.getAttribute('allow')).toBe('clipboard-write');
    wrapper.unmount();
  });
});
