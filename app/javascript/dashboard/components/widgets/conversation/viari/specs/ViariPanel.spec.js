import { flushPromises, mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import { webcrypto } from 'node:crypto';
import { createI18n } from 'vue-i18n';
import en from 'dashboard/i18n/locale/en/viari.json';
import api from 'dashboard/api/integrations/viari';
import Panel from '../ViariPanel.vue';
import Payment from '../ViariPaymentForm.vue';
import OrderActions from '../ViariOrderActions.vue';
import QuoteEditor from '../ViariQuoteEditor.vue';

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

describe('Viari conversation forms', () => {
  it('keeps the sale channel and global discount when editing quote notes', async () => {
    const wrapper = mount(QuoteEditor, {
      global,
      props: {
        read: vi.fn(),
        quote: {
          periodoInicio: '2026-12-01T00:00:00.000Z',
          periodoFim: '2026-12-02T00:00:00.000Z',
          dataValidade: '2026-11-30T00:00:00.000Z',
          percentualSinal: 35,
          descontoManualGeral: 0,
          descontoManual: 37,
          obsInternas: 'Nota anterior',
          msgCliente: null,
          canalVenda: {
            id: '9f06e65b-644d-44c8-8b89-79cb6f949ba1',
            nome: 'Balcão',
            grupoTarifaId: 'c397cb3b-ab79-47d7-9634-547d52adb3ab',
          },
          itens: [],
          passageiros: [],
        },
      },
    });

    const form = wrapper.get('form');
    await form.get('textarea').setValue('Nota atualizada');
    await form.trigger('submit');

    expect(wrapper.emitted('edit')).toEqual([
      [
        {
          operacao: 'cabecalho',
          periodoInicio: '2026-12-01',
          periodoFim: '2026-12-02',
          dataValidade: '2026-11-30',
          percentualSinal: 35,
          descontoManual: 0,
          obsInternas: 'Nota atualizada',
          msgCliente: '',
          canalVendaId: '9f06e65b-644d-44c8-8b89-79cb6f949ba1',
        },
      ],
    ]);
  });

  it('keeps the selected optional items when changing only the adult count', async () => {
    const extraId = '4dd66c91-337a-4fb0-a65b-77d9958ba7be';
    const wrapper = mount(QuoteEditor, {
      global,
      props: {
        read: vi.fn(),
        quote: {
          percentualSinal: 35,
          itens: [
            {
              id: 'quote-item',
              produtoNome: 'Passeio',
              dataDesejada: '2026-12-01T00:00:00.000Z',
              agendaId: 'schedule',
              qtdAdt: 1,
              detalhes: [
                { incluido: false, itemProdutoId: 'excluded-default' },
                { incluido: true, itemProdutoId: extraId },
              ],
            },
          ],
          passageiros: [],
        },
      },
    });

    await wrapper
      .findAll('button')
      .find(b => b.text().includes('Passeio'))
      .trigger('click');
    const itemForm = wrapper.findAll('form').at(-1);
    await itemForm.get('input').setValue('2');
    await itemForm.trigger('submit');

    expect(wrapper.emitted('edit')[0][0]).toMatchObject({
      operacao: 'item_editar',
      itemId: 'quote-item',
      qtdAdt: 2,
      itensSelecionados: [extraId],
    });
  });

  it('rebuilds the quote editor from the new server revision after a save', async () => {
    vi.stubGlobal('crypto', webcrypto);
    try {
      const revisao = '2026-11-28T00:00:00.000Z';
      let quote = {
        id: 'quote',
        codigo: 'ORC-123',
        status: 'rascunho',
        revisao,
        periodoInicio: '2026-12-01T00:00:00.000Z',
        periodoFim: '2026-12-01T00:00:00.000Z',
        dataValidade: '2026-11-30T00:00:00.000Z',
        percentualSinal: 35,
        obsInternas: 'Nota anterior',
        itens: [],
        passageiros: [],
      };
      api.read.mockImplementation(async (_conversation, action) => {
        if (action === 'contexto')
          return {
            clienteId: 'cliente',
            accountId: 9,
            userId: 17,
            acoes: ['orcamento_editar'],
          };
        if (action === 'cliente_detalhe')
          return {
            cliente: { id: 'cliente', nome: 'Ana' },
            orcamentos: [quote],
            reservas: [],
            pagamentos: [],
          };
        if (action === 'orcamento') return quote;
        throw new Error(action);
      });
      api.command.mockImplementation(async () => {
        quote = {
          ...quote,
          revisao: '2026-11-28T00:00:01.000Z',
          obsInternas: 'Nota normalizada',
        };
        return { ok: true };
      });

      const wrapper = mount(Panel, {
        global,
        props: {
          conversationId: 77,
          contact: { id: 87, name: 'Ana' },
        },
      });
      await flushPromises();
      await wrapper
        .findAll('button')
        .find(b => b.text().includes('ORC-123'))
        .trigger('click');
      await flushPromises();

      const header = () => wrapper.getComponent(QuoteEditor).get('form');
      await header().get('textarea').setValue('Nota enviada');
      await header().trigger('submit');
      await flushPromises();

      expect(api.command).toHaveBeenLastCalledWith(
        77,
        'orcamento_editar',
        expect.objectContaining({
          dados: expect.objectContaining({
            revisao,
            obsInternas: 'Nota enviada',
          }),
        }),
        expect.any(String),
        expect.any(AbortSignal)
      );
      expect(header().get('textarea').element.value).toBe('Nota normalizada');
      wrapper.unmount();
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('preserves passenger document, assistance flag and notes when editing the name', async () => {
    const persisted = {
      id: 'passenger',
      nome: 'Ana',
      tipoPax: 'ADT',
      idade: 35,
      documento: 'DOC-TUR-1',
      necessidadeEspecial: true,
      observacao: 'Solicitou apoio no embarque',
    };
    const reservation = {
      id: 'child-reservation',
      agenda: { produto: { nome: 'Passeio' } },
      atribuicoes: [{ passageiroId: 'group-passenger' }],
      passageiros: [persisted],
    };
    const command = vi.fn().mockResolvedValue({});
    const wrapper = mount(OrderActions, {
      global,
      props: {
        order: {
          grupoId: 'order',
          reservas: [reservation],
          passageiros: [
            { id: 'group-passenger', nome: 'Titular', tipoPax: 'ADT' },
          ],
        },
        can: action =>
          [
            'reserva_passageiro_editar',
            'reserva_passageiro_desatribuir',
          ].includes(action),
        command,
        read: vi.fn().mockResolvedValue(reservation),
      },
    });

    await wrapper.get('select').setValue(reservation.id);
    await flushPromises();
    expect(wrapper.text()).toContain(en.VIARI.UNASSIGN);
    await wrapper
      .findAll('button')
      .find(b => b.text() === en.VIARI.EDIT)
      .trigger('click');
    const form = wrapper.get('form');
    await form.get('input').setValue('Ana Maria');
    await form.trigger('submit');
    await flushPromises();

    expect(command).toHaveBeenCalledWith('reserva_passageiro_editar', {
      reservaId: reservation.id,
      dados: {
        passageiroId: persisted.id,
        nome: 'Ana Maria',
        tipoPax: persisted.tipoPax,
        idade: persisted.idade,
        documento: persisted.documento,
        necessidadeEspecial: persisted.necessidadeEspecial,
        observacao: persisted.observacao,
      },
    });
  });
  it('keeps an unlinked contact read-only until an explicit action and cancels reads on close', async () => {
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
    wrapper.unmount();
    expect(signal.aborted).toBe(true);
  });
  it('only posts a payment after a successful preview and invalidates the preview on editing', async () => {
    const command = vi.fn().mockResolvedValue({
      saldo: 90,
      condicao: 'pix',
      totalPago: 10,
      totalEfetivo: 100,
    });
    const wrapper = mount(Payment, {
      global,
      props: {
        order: { grupoId: 'order', codigo: '001' },
        partners: [],
        accounts: [],
        command,
      },
    });
    const amount = wrapper.get('input[type=number]');
    await amount.setValue('20');
    await wrapper.get('form').trigger('submit');
    await flushPromises();
    expect(command.mock.calls.map(c => c[0])).toEqual(['pagamento_previa']);
    expect(wrapper.text()).toContain('90');
    await amount.setValue('25');
    await wrapper.get('form').trigger('submit');
    await flushPromises();
    expect(command.mock.calls.map(c => c[0])).toEqual([
      'pagamento_previa',
      'pagamento_previa',
    ]);
    await wrapper.get('form').trigger('submit');
    await flushPromises();
    expect(command.mock.calls[2]).toEqual([
      'pagamento_registrar',
      {
        grupoId: 'order',
        dados: {
          valor: 25,
          metodo: 'pix',
          tipoPagamento: 'sinal',
          recebedorTipo: 'empresa',
          parcelas: 1,
        },
      },
    ]);
    wrapper.unmount();
  });
});
