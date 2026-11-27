import { flushPromises, shallowMount } from '@vue/test-utils';

import AgentsAPI from 'dashboard/api/agents';
import { useAlert } from 'dashboard/composables';
import AgentInboxAccess from '../AgentInboxAccess.vue';

vi.mock('dashboard/api/agents', () => ({
  default: { getInboxAccess: vi.fn(), updateInboxAccess: vi.fn() },
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));

const pilot = {
  id: 10,
  name: 'Pilot',
  access_level: 'agent',
  supervision_available: true,
};
const otherInbox = {
  id: 11,
  name: 'Other inbox',
  access_level: 'none',
  supervision_available: false,
};

const mountEditor = () =>
  shallowMount(AgentInboxAccess, {
    props: { agentId: 5 },
    global: {
      stubs: {
        Button: {
          props: ['label', 'disabled'],
          template: '<button :disabled="disabled">{{ label }}</button>',
        },
      },
    },
  });

describe('AgentInboxAccess', () => {
  let wrapper;

  beforeEach(() => {
    vi.resetAllMocks();
    AgentsAPI.getInboxAccess.mockResolvedValue({ data: [pilot, otherInbox] });
  });

  afterEach(() => wrapper?.unmount());

  it('shows supervision only in eligible inboxes', async () => {
    wrapper = mountEditor();
    await flushPromises();

    const [pilotSelect, otherSelect] = wrapper.findAll('select');
    expect(AgentsAPI.getInboxAccess).toHaveBeenCalledWith(5);
    expect(pilotSelect.element.value).toBe('agent');
    expect(pilotSelect.find('option[value="supervisor"]').exists()).toBe(true);
    expect(otherSelect.find('option[value="supervisor"]').exists()).toBe(false);
  });

  it('updates one inbox at a time and uses the saved server level', async () => {
    AgentsAPI.updateInboxAccess.mockResolvedValue({
      data: { ...pilot, access_level: 'supervisor' },
    });
    wrapper = mountEditor();
    await flushPromises();

    const [pilotSelect, otherSelect] = wrapper.findAll('select');
    const [pilotButton] = wrapper.findAll('button');
    expect(pilotButton.element.disabled).toBe(true);
    await pilotSelect.setValue('supervisor');
    await pilotButton.trigger('click');
    await flushPromises();

    expect(AgentsAPI.updateInboxAccess).toHaveBeenCalledExactlyOnceWith(
      5,
      10,
      'supervisor'
    );
    expect(pilotButton.element.disabled).toBe(true);
    expect(otherSelect.element.value).toBe('none');
  });

  it('preserves a failed edit for retry', async () => {
    AgentsAPI.updateInboxAccess.mockRejectedValue(new Error('Unavailable'));
    wrapper = mountEditor();
    await flushPromises();

    const [pilotSelect] = wrapper.findAll('select');
    const [pilotButton] = wrapper.findAll('button');
    await pilotSelect.setValue('none');
    await pilotButton.trigger('click');
    await flushPromises();

    expect(useAlert).toHaveBeenCalledWith('AGENT_MGMT.INBOX_ACCESS.SAVE_ERROR');
    expect(pilotButton.element.disabled).toBe(false);
    expect(pilotSelect.element.value).toBe('none');
  });

  it('hides the editor when the account has no pilot inbox', async () => {
    AgentsAPI.getInboxAccess.mockResolvedValue({ data: [] });
    wrapper = mountEditor();
    await flushPromises();

    expect(wrapper.get('fieldset').isVisible()).toBe(false);
  });
});
