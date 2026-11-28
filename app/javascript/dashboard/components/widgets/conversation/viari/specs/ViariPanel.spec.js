import { flushPromises, mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import { webcrypto } from 'node:crypto';
import NativeModal from '../ViariNativeModal.vue';
import { createI18n } from 'vue-i18n';
import en from 'dashboard/i18n/locale/en/viari.json';
import api from 'dashboard/api/integrations/viari';
import Panel from '../ViariPanel.vue';

vi.mock('dashboard/api/integrations/viari', () => ({
  default: { read: vi.fn(), command: vi.fn() },
}));
const global = {
  plugins: [
    createI18n({
      legacy: false,
      globalInstall: false,
      locale: 'en',
      messages: { en },
    }),
  ],
};

describe('Viari conversation summary', () => {
  it('keeps negotiations separate and renders official totals and zero passenger categories', async () => {
    api.read.mockImplementation(async (_id, action) => {
      if (action === 'contexto') return { clienteId: 'customer', acoes: [] };
      if (action === 'cliente_detalhe') return { cliente: { nome: 'Ana' } };
      if (action === 'resumo_comercial')
        return {
          negociacoes: [
            {
              id: 'orcamento:1',
              tipo: 'orcamento',
              codigo: 'ORC-1',
              orcamentoIds: ['1'],
              grupoIds: ['2'],
              reservaIds: [],
              passeios: [
                {
                  id: 'a',
                  produtoNome: 'Tour A',
                  data: '2026-12-02',
                  totalPax: 2,
                  valor: 37.5,
                  qtdAdt: 2,
                  qtdChd: 0,
                  qtdInf: 0,
                  qtdSen: 0,
                  qtdFree: 0,
                },
              ],
              financeiro: { total: 150, pago: null, saldo: null },
            },
            {
              id: 'os:2',
              tipo: 'os',
              codigo: 'OS-2',
              orcamentoIds: ['1'],
              reservaIds: [],
              grupoIds: ['2'],
              grupoId: '2',
              passeios: [
                {
                  id: 'b',
                  produtoNome: 'Tour B',
                  data: '2026-12-03',
                  qtdAdt: 1,
                },
              ],
              financeiro: { total: 200, pago: 80, saldo: 120 },
            },
          ],
        };
      throw new Error(action);
    });
    const wrapper = mount(Panel, {
      global,
      props: { conversationId: 7, contact: { id: 8 } },
    });
    await flushPromises();
    expect(wrapper.text()).toContain('Tour A');
    expect(wrapper.text()).not.toContain('Tour B');
    expect(wrapper.text()).toContain('CHD 0');
    expect(wrapper.text()).toContain('02/12/2026');
    expect(wrapper.get('li').text()).toContain('37.50');
    await wrapper.get('select').setValue('os:2');
    expect(wrapper.text()).toContain('Tour B');
    expect(wrapper.get('li').text()).toContain('—');
    expect(wrapper.text()).not.toContain('Tour A');
    expect(wrapper.text()).toContain('80.00');
    expect(wrapper.text()).toContain('120.00');
    await wrapper
      .findAll('button')
      .find(button => button.text() === en.VIARI.QUOTE_STAGE)
      .trigger('click');
    expect(wrapper.text()).toContain('Tour A');
    expect(wrapper.text()).not.toContain('Tour B');
    wrapper.unmount();
  });
  it('selects the newly converted order after refreshing the same quote', async () => {
    vi.stubGlobal('crypto', webcrypto);
    HTMLDialogElement.prototype.showModal = vi.fn();
    const quote = {
      id: 'orcamento:1',
      tipo: 'orcamento',
      codigo: 'Q1',
      orcamentoIds: ['1'],
      grupoIds: [],
      reservaIds: [],
      passeios: [],
      financeiro: {},
    };
    const order = {
      id: 'os:2',
      tipo: 'os',
      codigo: 'OS2',
      orcamentoIds: ['1'],
      grupoIds: ['2'],
      grupoId: '2',
      reservaIds: [],
      passeios: [{ id: 'tour', produtoNome: 'Converted tour', totalPax: 1 }],
      financeiro: { total: 150, pago: 50, saldo: 100 },
    };
    let converted = false;
    api.read.mockImplementation(async (_id, action) => {
      if (action === 'contexto')
        return { clienteId: 'customer', accountId: 1, userId: 5, acoes: [] };
      if (action === 'cliente_detalhe') return { cliente: { nome: 'Ana' } };
      return {
        negociacoes: converted
          ? [{ ...quote, grupoIds: ['2'] }, order]
          : [quote],
      };
    });
    api.command.mockResolvedValue({
      url: 'https://viari.example/atendimento/nativo',
      origin: 'https://viari.example',
      channel: 'converted',
      mode: 'iframe',
    });
    const wrapper = mount(Panel, {
      global,
      props: { conversationId: 7, contact: { id: 8 } },
    });
    try {
      await flushPromises();
      converted = true;
      await wrapper
        .findAll('button')
        .find(button => button.text() === en.VIARI.REFRESH)
        .trigger('click');
      await flushPromises();
      await wrapper
        .findAll('button')
        .find(button => button.text() === en.VIARI.ORDER)
        .trigger('click');
      expect(wrapper.text()).toContain('Converted tour');
      expect(wrapper.text()).toContain('100.00');
      await wrapper
        .findAll('button')
        .find(button => button.text() === en.VIARI.OPEN_NATIVE)
        .trigger('click');
      await flushPromises();
      expect(api.command).toHaveBeenLastCalledWith(
        7,
        'abrir_nativo',
        { dados: { destino: 'os', grupoId: '2' } },
        expect.any(String),
        expect.any(AbortSignal)
      );
      expect(wrapper.get('select').element.value).toBe('orcamento:1');
      wrapper
        .getComponent(NativeModal)
        .vm.$emit('navigate', { destino: 'pagamento', grupoId: '2' });
      await flushPromises();
      expect(wrapper.get('select').element.value).toBe('os:2');
      expect(wrapper.find('button[aria-current=step]').text()).toBe(
        en.VIARI.PAYMENT_STAGE
      );
      api.command.mockRejectedValueOnce(new Error('Launch failed'));
      wrapper.getComponent(NativeModal).vm.$emit('navigate', {
        destino: 'orcamento_editar',
        orcamentoId: '1',
      });
      await flushPromises();
      expect(wrapper.findComponent(NativeModal).exists()).toBe(true);
      expect(wrapper.get('select').element.value).toBe('os:2');
      expect(wrapper.get('[role=alert]').text()).toBe(en.VIARI.ERROR);
    } finally {
      wrapper.unmount();
      vi.unstubAllGlobals();
    }
  });
  it.each(['pagamento', 'cliente_editar'])(
    'relaunches the native workspace for %s after conversion or customer creation',
    async destino => {
      vi.stubGlobal('crypto', webcrypto);
      HTMLDialogElement.prototype.showModal = vi.fn();
      api.command.mockClear();
      api.read.mockResolvedValue({
        clienteId: null,
        accountId: 1,
        userId: 5,
        acoes: ['cliente_criar'],
      });
      api.command.mockResolvedValue({
        url: 'https://viari.example/atendimento/nativo?ticket=launch',
        origin: 'https://viari.example',
        channel: 'launch',
        mode: 'iframe',
      });
      const wrapper = mount(Panel, {
        global,
        props: { conversationId: 7, contact: { id: 8 } },
      });
      try {
        await flushPromises();
        await wrapper
          .findAll('button')
          .find(button => button.text() === en.VIARI.NEW_CUSTOMER)
          .trigger('click');
        await flushPromises();
        expect(wrapper.findComponent(NativeModal).exists()).toBe(true);
        wrapper.getComponent(NativeModal).vm.$emit('navigate', {
          destino,
          grupoId: 'converted-order',
          url: 'https://attacker.example',
        });
        await flushPromises();
        expect(api.command).toHaveBeenLastCalledWith(
          7,
          'abrir_nativo',
          { dados: { destino, grupoId: 'converted-order' } },
          expect.any(String),
          expect.any(AbortSignal)
        );
        expect(wrapper.getComponent(NativeModal).props('session').url).toBe(
          'https://viari.example/atendimento/nativo?ticket=launch'
        );
      } finally {
        wrapper.unmount();
        vi.unstubAllGlobals();
      }
    }
  );
  it('keeps an unlinked contact read-only until explicit confirmation', async () => {
    HTMLDialogElement.prototype.showModal = vi.fn();
    HTMLDialogElement.prototype.close = vi.fn();
    api.command.mockClear();
    let signal;
    api.read.mockImplementation(async (_conversation, action, _args, s) => {
      signal = s;
      if (action === 'contexto')
        return {
          clienteId: null,
          accountId: 1,
          userId: 5,
          acoes: ['cliente_criar', 'cliente_vincular'],
        };
      if (action === 'cliente_buscar')
        return { clientes: [{ id: 'mock', nome: 'Ana', telefone: '1234' }] };
      throw new Error(action);
    });
    const wrapper = mount(Panel, {
      global,
      props: {
        conversationId: 7,
        contact: { id: 8, name: 'Ana', phone_number: '1234' },
      },
    });
    await flushPromises();
    expect(api.command).not.toHaveBeenCalled();
    await wrapper
      .findAll('button')
      .find(b => b.text().includes('Search'))
      .trigger('click');
    await flushPromises();
    expect(wrapper.text()).toContain('Confirm link');
    expect(api.command).not.toHaveBeenCalled();
    expect(signal).toBeInstanceOf(AbortSignal);
    wrapper.unmount();
  });
});
