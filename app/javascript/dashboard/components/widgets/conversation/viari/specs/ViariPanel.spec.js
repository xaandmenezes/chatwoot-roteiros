import { flushPromises, mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import { webcrypto } from 'node:crypto';
import NativeModal from '../ViariNativeModal.vue';
import { createI18n } from 'vue-i18n';
import ptBR from 'dashboard/i18n/locale/pt_BR/viari.json';
import { copyTextToClipboard } from 'shared/helpers/clipboard';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import en from 'dashboard/i18n/locale/en/viari.json';
import api from 'dashboard/api/integrations/viari';
import Panel from '../ViariPanel.vue';

vi.mock('../intention', () => ({
  runIntention: (_scope, _action, _params, send) => send('idempotency-key'),
}));
vi.mock('shared/helpers/clipboard', () => ({ copyTextToClipboard: vi.fn() }));
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
                  valorNormal: 40,
                  valorPix: 35,
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
                  status: 'cancelada',
                  valor: 200,
                  valorFinanceiro: 15,
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
    expect(wrapper.get('li').text()).not.toContain('37.50');
    expect(wrapper.get('li').text()).not.toContain(en.VIARI.CURRENT_AMOUNT);
    expect(wrapper.get('li').text()).toContain(en.VIARI.PIX_CASH);
    expect(wrapper.get('li').text()).not.toContain(en.VIARI.RECORDED_PIX);
    expect(wrapper.text()).not.toContain(en.VIARI.EFFECTIVE_TOTAL);
    expect(wrapper.get('li').text()).toContain('40.00');
    expect(wrapper.get('li').text()).toContain('35.00');
    await wrapper.get('select').setValue('os:2');
    expect(wrapper.text()).toContain('Tour B');
    expect(wrapper.get('li').text()).toContain('15.00');
    expect(wrapper.get('li').text()).toContain(en.VIARI.RETENTION_FINANCIAL);
    expect(wrapper.get('li').text()).toContain(en.VIARI.CANCELED_ACTIVITY);
    expect(wrapper.get('li').text()).toContain(en.VIARI.RECORDED_PIX);
    expect(wrapper.get('li').text()).toContain(en.VIARI.RECORDED_CARD);
    expect(wrapper.get('li').text()).not.toContain('200.00');
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
      financeiro: {
        total: 150,
        pago: 50,
        saldo: 100,
        saldoPix: 75,
        saldoCartao: 100,
        totalPixAplicavel: 125,
        condicao: 'normal',
      },
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
      expect(wrapper.text()).toContain('75.00');
      expect(wrapper.text()).toContain('125.00');
      expect(wrapper.text()).toContain(en.VIARI.EFFECTIVE_TOTAL);
      expect(wrapper.text()).toContain(en.VIARI.RECORDED_PIX);
      expect(wrapper.text()).toContain(en.VIARI.NORMAL_APPLIED);
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
      api.command.mockReset();
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
  it('uses compact Portuguese stages and copies the official proposal without sending it', async () => {
    vi.stubGlobal('crypto', webcrypto);
    const officialText =
      '🏠 Orçamento dos passeios:\nNome: Ana\nValor oficial: R$ 150,00';
    const emit = vi.spyOn(emitter, 'emit');
    api.command.mockReset();
    copyTextToClipboard.mockResolvedValue();
    api.read.mockImplementation(async (_id, action) => {
      if (action === 'contexto')
        return {
          clienteId: 'customer',
          accountId: 1,
          userId: 5,
          acoes: ['orcamento_enviar', 'orcamento_texto'],
        };
      if (action === 'cliente_detalhe') return { cliente: { nome: 'Ana' } };
      if (action === 'orcamento')
        return { orcamento: { revisao: 'revision-1' } };
      if (action === 'orcamento_texto')
        return { status: 'rascunho', textoWhatsapp: officialText };
      return {
        negociacoes: [
          {
            id: 'orcamento:1',
            tipo: 'orcamento',
            codigo: 'Q1',
            status: 'rascunho',
            orcamentoIds: ['1'],
            grupoIds: [],
            reservaIds: [],
            passeios: [],
            financeiro: {},
          },
        ],
      };
    });
    api.command.mockResolvedValue({
      textoWhatsapp: officialText,
      urlProposta: 'https://viari.example/proposta',
      urlPdf: 'https://viari.example/pdf',
    });
    const wrapper = mount(Panel, {
      global: {
        plugins: [
          createI18n({
            legacy: false,
            locale: 'pt_BR',
            fallbackLocale: 'en',
            messages: { en, pt_BR: ptBR },
          }),
        ],
      },
      props: { conversationId: 7, contact: { id: 8 } },
    });
    try {
      await flushPromises();
      expect(wrapper.get('nav').text()).toBe('Orçamento—OS—Pagamento');
      expect(wrapper.text()).toContain(ptBR.VIARI.COPY_PROPOSAL);
      await wrapper
        .findAll('button')
        .find(button => button.text() === ptBR.VIARI.COPY_PROPOSAL)
        .trigger('click');
      await flushPromises();
      expect(api.read).toHaveBeenLastCalledWith(
        7,
        'orcamento_texto',
        { orcamentoId: '1' },
        expect.any(AbortSignal)
      );
      expect(copyTextToClipboard).toHaveBeenLastCalledWith(officialText);
      expect(api.command).not.toHaveBeenCalled();
      await wrapper
        .findAll('button')
        .find(button => button.text() === ptBR.VIARI.MARK_PROPOSAL_SENT)
        .trigger('click');
      await flushPromises();
      await vi.waitFor(() => {
        expect(api.command).toHaveBeenLastCalledWith(
          7,
          'orcamento_enviar',
          { orcamentoId: '1', dados: { revisao: 'revision-1' } },
          expect.any(String),
          expect.any(AbortSignal)
        );
      });
      await flushPromises();
      expect(emit).not.toHaveBeenCalled();
      await wrapper
        .findAll('button')
        .find(button => button.text() === ptBR.VIARI.COPY_PROPOSAL)
        .trigger('click');
      await flushPromises();
      expect(copyTextToClipboard).toHaveBeenLastCalledWith(officialText);
      expect(wrapper.text()).toContain(ptBR.VIARI.PROPOSAL_COPIED);
      expect(emit).not.toHaveBeenCalled();
      await wrapper
        .findAll('button')
        .find(button => button.text() === ptBR.VIARI.COMPOSER)
        .trigger('click');
      expect(emit).toHaveBeenLastCalledWith(
        BUS_EVENTS.INSERT_INTO_RICH_EDITOR,
        officialText
      );
      expect(api.command).toHaveBeenCalledTimes(1);
      copyTextToClipboard.mockRejectedValueOnce(new Error('Clipboard denied'));
      await wrapper
        .findAll('button')
        .find(button => button.text() === ptBR.VIARI.COPY_PROPOSAL)
        .trigger('click');
      await flushPromises();
      expect(wrapper.get('[role=alert]').text()).toBe(ptBR.VIARI.ERROR);
      expect(wrapper.text()).not.toContain(ptBR.VIARI.PROPOSAL_COPIED);
    } finally {
      wrapper.unmount();
      emit.mockRestore();
      vi.unstubAllGlobals();
    }
  });
  it('discards in-flight proposal text and clears composer text when changing related quotes', async () => {
    copyTextToClipboard.mockClear();
    let resolveText;
    const pendingText = new Promise(resolve => {
      resolveText = resolve;
    });
    const makeQuote = id => ({
      id: 'orcamento:' + id,
      tipo: 'orcamento',
      codigo: id,
      orcamentoIds: [id],
      grupoIds: ['g'],
      reservaIds: [],
      passeios: [],
      financeiro: {},
    });
    api.read.mockImplementation(async (_id, action, params) => {
      if (action === 'contexto')
        return { clienteId: 'customer', acoes: ['orcamento_texto'] };
      if (action === 'cliente_detalhe') return { cliente: { nome: 'Ana' } };
      if (action === 'orcamento_texto')
        return params.orcamentoId === '1'
          ? pendingText
          : { textoWhatsapp: 'Quote two' };
      return {
        negociacoes: [
          {
            id: 'os:g',
            tipo: 'os',
            codigo: 'OS',
            orcamentoIds: ['1', '2'],
            grupoIds: ['g'],
            grupoId: 'g',
            reservaIds: [],
            passeios: [],
            financeiro: {},
          },
          makeQuote('1'),
          makeQuote('2'),
        ],
      };
    });
    const wrapper = mount(Panel, {
      global,
      props: { conversationId: 7, contact: { id: 8 } },
    });
    try {
      await flushPromises();
      await wrapper
        .findAll('button')
        .find(button => button.text() === en.VIARI.QUOTE_STAGE)
        .trigger('click');
      await wrapper
        .findAll('button')
        .find(button => button.text() === en.VIARI.COPY_PROPOSAL)
        .trigger('click');
      await wrapper.get('select[aria-label="Quote"]').setValue('orcamento:2');
      resolveText({ textoWhatsapp: 'Stale quote one' });
      await flushPromises();
      expect(copyTextToClipboard).not.toHaveBeenCalled();
      expect(wrapper.text()).not.toContain(en.VIARI.COMPOSER);
      await wrapper
        .findAll('button')
        .find(button => button.text() === en.VIARI.COPY_PROPOSAL)
        .trigger('click');
      await flushPromises();
      expect(copyTextToClipboard).toHaveBeenLastCalledWith('Quote two');
      expect(wrapper.text()).toContain(en.VIARI.COMPOSER);
      await wrapper.get('select[aria-label="Quote"]').setValue('orcamento:1');
      expect(wrapper.text()).not.toContain(en.VIARI.COMPOSER);
      expect(wrapper.text()).not.toContain(en.VIARI.PROPOSAL_COPIED);
    } finally {
      wrapper.unmount();
    }
  });
  it('keeps an unlinked contact read-only until explicit confirmation', async () => {
    HTMLDialogElement.prototype.showModal = vi.fn();
    HTMLDialogElement.prototype.close = vi.fn();
    api.command.mockReset();
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
