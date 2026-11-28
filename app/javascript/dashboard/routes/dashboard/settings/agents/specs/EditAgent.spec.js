import { flushPromises, mount } from '@vue/test-utils';
import AgentsAPI from 'dashboard/api/agents';
import EditAgent from '../EditAgent.vue';

const { dispatch } = vi.hoisted(() => ({ dispatch: vi.fn() }));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
  useMapGetter: key => ({
    value: key === 'customRole/getCustomRoles' ? [] : {},
  }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/api/auth', () => ({ default: {} }));
vi.mock('dashboard/api/agents', () => ({
  default: { getInboxAccess: vi.fn(), updateInboxAccess: vi.fn() },
}));

it('applies inbox access before the footer without submitting profile changes', async () => {
  const inbox = { id: 12, name: 'Ryze 2', access_level: 'none' };
  AgentsAPI.getInboxAccess.mockResolvedValue({ data: [inbox] });
  AgentsAPI.updateInboxAccess.mockResolvedValue({
    data: { ...inbox, access_level: 'agent' },
  });

  const wrapper = mount(EditAgent, {
    attachTo: document.body,
    props: { id: 5, name: 'Piloto', type: 'agent', availability: 'offline' },
  });
  try {
    await flushPromises();
    const form = wrapper.get('form');
    const access = form.get('fieldset');
    const submit = form.get('button[type="submit"]');
    expect(access.element.compareDocumentPosition(submit.element)).toBe(
      Node.DOCUMENT_POSITION_FOLLOWING
    );
    await form.get('input').setValue('Novo nome');
    await access.get('select').setValue('agent');
    await access.get('button').trigger('click');
    await flushPromises();
    expect(AgentsAPI.updateInboxAccess).toHaveBeenCalledExactlyOnceWith(
      5,
      12,
      'agent'
    );
    expect(dispatch).not.toHaveBeenCalled();
    expect(wrapper.emitted('close')).toBeUndefined();
    await submit.trigger('click');
    expect(dispatch).toHaveBeenCalledWith('agents/update', {
      id: 5,
      name: 'Novo nome',
      role: 'agent',
      custom_role_id: null,
      availability: 'offline',
    });
  } finally {
    wrapper.unmount();
  }
});
