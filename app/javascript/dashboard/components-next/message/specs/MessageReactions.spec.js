import { flushPromises, mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { withFullI18n } from 'test-i18n';
import MessageApi from 'dashboard/api/inbox/message';
import MessageReactions from '../MessageReactions.vue';

vi.mock('dashboard/api/inbox/message', () => ({
  default: { react: vi.fn() },
}));

withFullI18n('en');

describe('message reactions', () => {
  const render = props => {
    const update = vi.fn();
    const store = createStore({
      mutations: { UPDATE_MESSAGE_RYZE_REACTIONS: update },
    });
    const wrapper = mount(MessageReactions, {
      props: { messageId: 200, conversationId: 71, ...props },
      global: { plugins: [store], stubs: { EmojiIconPicker: true } },
    });
    return { wrapper, update };
  };

  beforeEach(() => {
    MessageApi.react.mockReset();
  });

  it('shows both authors even if they reacted with the same emoji', () => {
    const { wrapper } = render({
      reactions: {
        incoming: { emoji: '👍', author: 'Customer' },
        outgoing: { emoji: '👍', author: 'Agent' },
      },
    });

    expect(
      wrapper
        .findAll('[role="img"]')
        .map(badge => badge.attributes('aria-label'))
    ).toEqual(['Customer reacted with 👍', 'Agent reacted with 👍']);
    expect(wrapper.find('button').exists()).toBe(false);
  });

  it('posts a removal once and waits for server state before removing the emoji', async () => {
    let resolve;
    MessageApi.react.mockReturnValue(
      new Promise(done => {
        resolve = done;
      })
    );
    const { wrapper, update } = render({
      canReact: true,
      reactions: { outgoing: { emoji: '👍', author: 'Agent' } },
    });
    await wrapper.get('button').trigger('click');
    await flushPromises();
    const picker = wrapper.getComponent({ name: 'EmojiIconPicker' });
    picker.vm.$emit('remove');
    picker.vm.$emit('remove');
    await flushPromises();

    expect(MessageApi.react).toHaveBeenCalledExactlyOnceWith(71, 200, '');
    expect(wrapper.get('[role="img"]').text()).toBe('👍');

    const data = {
      id: 200,
      conversation_id: 71,
      ryze_reactions: { revision: 2, pending: false, outgoing: null },
    };
    resolve({ data });
    await flushPromises();

    expect(update).toHaveBeenCalledExactlyOnceWith({}, data);
    await wrapper.setProps({ reactions: data.ryze_reactions });
    expect(wrapper.find('[role="img"]').exists()).toBe(false);
  });

  it('disables the action when the provider result is pending', () => {
    const { wrapper } = render({
      canReact: true,
      reactions: { pending: true },
    });

    expect(wrapper.get('button').attributes()).toHaveProperty('disabled');
    expect(wrapper.get('[role="status"]').text()).toContain(
      'Waiting for WhatsApp'
    );
  });
});
