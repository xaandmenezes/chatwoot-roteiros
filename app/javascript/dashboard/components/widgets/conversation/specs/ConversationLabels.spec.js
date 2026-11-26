import { nextTick } from 'vue';
import { createStore } from 'vuex';
import { flushPromises, shallowMount } from '@vue/test-utils';
import ConversationCard from '../ConversationCard.vue';
import ConversationCardExpanded from 'dashboard/components-next/Conversation/ConversationCard/ConversationCardExpanded.vue';
import ConversationHeader from '../ConversationHeader.vue';

vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRoute: () => ({ params: {} }),
}));

vi.mock('dashboard/routes/index', () => ({ default: {} }));

vi.mock('dashboard/composables/useInbox', () => ({
  useInbox: () => ({ isAWebWidgetInbox: false, isAnEmailChannel: false }),
}));

const contact = { id: 71, name: 'Test Contact' };
const inbox = { id: 1 };
const accountLabels = [
  { id: 3, title: 'agenda', color: '#0000ff' },
  { id: 1, title: 'direct-insta', color: '#008000' },
  { id: 2, title: 'instagram', color: '#ff0000' },
];
const createChat = (overrides = {}) => ({
  id: 1,
  meta: { sender: contact },
  inbox_id: inbox.id,
  labels: [],
  contact_labels: ['direct-insta'],
  messages: [],
  unread_count: 0,
  timestamp: 1700000000,
  created_at: 1700000000,
  ...overrides,
});

const mountComponent = (component, chat) => {
  const store = createStore({
    getters: {
      getSelectedChat: () => chat,
      getCurrentAccountId: () => 1,
      'contacts/getContact': () => () => contact,
      'inboxes/getInbox': () => () => inbox,
      'inboxes/getInboxes': () => [inbox],
      'labels/getLabels': () => accountLabels,
    },
  });

  return shallowMount(component, {
    attachTo: document.body,
    props:
      component === ConversationHeader
        ? { chat }
        : { chat, currentContact: contact, inbox },
    global: {
      plugins: [store],
      stubs: {
        ConversationLabels: false,
        Label: false,
        Popover: false,
        TeleportWithDirection: false,
        teleport: true,
        'fluent-icon': true,
      },
    },
  });
};

describe('Conversation labels', () => {
  let wrapper;
  let rowWidth;

  beforeEach(() => {
    rowWidth = 250;
    vi.spyOn(HTMLElement.prototype, 'clientWidth', 'get').mockImplementation(
      () => rowWidth
    );
    vi.spyOn(HTMLElement.prototype, 'offsetWidth', 'get').mockReturnValue(64);
  });

  afterEach(() => {
    wrapper?.unmount();
    vi.restoreAllMocks();
  });

  it.each([
    ['compact card', ConversationCard],
    ['expanded card', ConversationCardExpanded],
    ['open conversation header', ConversationHeader],
  ])('shows an imported contact label in the %s', async (_, component) => {
    wrapper = mountComponent(component, createChat());
    await nextTick();

    expect(wrapper.text()).toContain('direct-insta');
  });

  it('shows conversation and contact labels with each title listed once', async () => {
    wrapper = mountComponent(
      ConversationHeader,
      createChat({
        labels: ['instagram'],
        contact_labels: ['instagram', 'direct-insta'],
      })
    );
    await nextTick();

    expect(wrapper.text().match(/instagram/g)).toHaveLength(1);
    expect(wrapper.text()).toContain('direct-insta');
  });

  it('updates the header when switching conversations', async () => {
    wrapper = mountComponent(ConversationHeader, createChat());
    await wrapper.setProps({
      chat: createChat({ id: 2, labels: ['agenda'], contact_labels: [] }),
    });

    expect(wrapper.text()).not.toContain('direct-insta');
    expect(wrapper.text()).toContain('agenda');
    await wrapper.setProps({ chat: createChat({ id: 3, contact_labels: [] }) });
    expect(wrapper.findComponent({ name: 'ConversationLabels' }).exists()).toBe(
      false
    );
  });

  it('reveals labels in a narrow card without opening the conversation', async () => {
    rowWidth = 120;
    wrapper = mountComponent(
      ConversationCard,
      createChat({ labels: ['instagram', 'agenda'] })
    );
    await nextTick();

    const toggle = wrapper.get('button[aria-expanded]');
    expect(toggle.text()).toBe('+2');
    expect(toggle.attributes('aria-expanded')).toBe('false');
    await toggle.trigger('click');
    await flushPromises();

    expect(toggle.attributes('aria-expanded')).toBe('true');
    const disclosedLabels = wrapper.get('[role="region"]');
    expect(document.activeElement).toBe(disclosedLabels.element);
    expect(toggle.attributes('aria-controls')).toBe(
      disclosedLabels.attributes('id')
    );
    expect(disclosedLabels.text()).toContain('instagram');
    expect(disclosedLabels.text()).toContain('direct-insta');
    expect(wrapper.emitted('click')).toBeUndefined();

    await disclosedLabels.trigger('keydown', { key: 'Escape' });
    expect(toggle.attributes('aria-expanded')).toBe('false');
    expect(document.activeElement).toBe(toggle.element);
  });
});
