import { flushPromises, shallowMount } from '@vue/test-utils';
import { createMemoryHistory, createRouter } from 'vue-router';
import { createStore } from 'vuex';
import { emitter } from 'shared/helpers/mitt';
import { CMD_SWITCH_TAB } from 'dashboard/helper/commandbar/events';
import wootConstants from 'dashboard/constants/globals';
import conversationGetters from 'dashboard/store/modules/conversations/getters';
import ChatList from '../ChatList.vue';
import ConversationList from '../ConversationList.vue';
import ChatTypeTabs from '../widgets/ChatTypeTabs.vue';

const GROUPS = wootConstants.CONVERSATION_TYPE.WHATSAPP_GROUPS;
const user = {
  id: 1,
  accounts: [{ id: 1, role: 'agent', permissions: ['agent'] }],
};
const conversations = [
  { id: 1, whatsapp_group: true, meta: { assignee: { id: 1 } } },
  { id: 2, whatsapp_group: true, meta: { assignee: { id: 2 } } },
  { id: 3, whatsapp_group: true, meta: {} },
  { id: 4, whatsapp_group: false, meta: { assignee: { id: 1 } } },
].map(chat => ({ status: 'open', inbox_id: 2, ...chat }));

const routes = [
  { path: '/:accountId/conversations', name: 'home' },
  { path: '/:accountId/groups', name: 'whatsapp_groups' },
  {
    path: '/:accountId/groups/:conversation_id',
    name: 'conversation_through_whatsapp_groups',
  },
].map(route => ({ ...route, component: { template: '<div />' } }));

const mountList = async (path, conversationType = '', viewer = user) => {
  const router = createRouter({ history: createMemoryHistory(), routes });
  await router.push(path);

  const store = createStore({
    state: { allConversations: conversations, groupsPage: 0 },
    getters: {
      getCurrentUser: () => viewer,
      getCurrentAccountId: () => 1,
      getCurrentRole: () => 'agent',
      getUISettings: () => ({}),
      getSelectedInbox: () => 2,
      getChatListLoadingStatus: () => false,
      'inboxes/getInbox': () => () => ({}),
      'bulkActions/getSelectedConversationIds': () => [],
      'conversationStats/getStats': () => ({ mineCount: 1, allCount: 26 }),
      'conversationPage/getCurrentPageFilter': state => filter =>
        filter === 'all' ? state.groupsPage : 0,
      'conversationPage/getHasEndReached': () => () => false,
      getAppliedConversationFiltersV2: () => [],
      getAllStatusChats: conversationGetters.getAllStatusChats,
      getMineChats: conversationGetters.getMineChats,
      getUnAssignedChats: conversationGetters.getUnAssignedChats,
    },
  });
  const dispatch = vi.spyOn(store, 'dispatch').mockResolvedValue();
  const wrapper = shallowMount(ChatList, {
    props: { conversationType },
    global: { plugins: [router, store] },
  });
  return { wrapper, router, store, dispatch };
};

const conversationIds = wrapper =>
  wrapper
    .getComponent(ConversationList)
    .props('conversationList')
    .map(conversation => conversation.id);

describe('ChatList WhatsApp groups', () => {
  let mounted;

  afterEach(() => {
    mounted?.wrapper.unmount();
    mounted = undefined;
  });

  it.each(['/1/groups', '/1/groups/1'])(
    'shows all accessible open groups with no assignment tabs at %s',
    async path => {
      mounted = await mountList(path, GROUPS);
      const { wrapper, store, dispatch } = mounted;

      expect(wrapper.findComponent(ChatTypeTabs).exists()).toBe(false);
      expect(conversationIds(wrapper)).toEqual([1, 2, 3]);
      expect(dispatch).toHaveBeenCalledWith(
        'updateChatListFilters',
        expect.objectContaining({
          assigneeType: 'all',
          whatsappScope: 'groups',
          page: 1,
        })
      );

      dispatch.mockClear();
      emitter.emit(CMD_SWITCH_TAB, 'unassigned');
      await flushPromises();

      expect(dispatch).not.toHaveBeenCalled();
      expect(conversationIds(wrapper)).toEqual([1, 2, 3]);

      store.state.groupsPage = 1;
      wrapper.getComponent(ConversationList).vm.$emit('loadMore');

      expect(dispatch).toHaveBeenCalledWith(
        'updateChatListFilters',
        expect.objectContaining({
          assigneeType: 'all',
          whatsappScope: 'groups',
          page: 2,
        })
      );
    }
  );

  it('lists only assigned-to-me and unassigned groups for a restricted agent', async () => {
    const viewer = {
      ...user,
      accounts: [
        {
          id: 1,
          role: 'agent',
          custom_role_id: 1,
          permissions: ['custom_role', 'conversation_unassigned_manage'],
        },
      ],
    };
    mounted = await mountList('/1/groups', GROUPS, viewer);
    const { wrapper, dispatch } = mounted;

    expect(conversationIds(wrapper)).toEqual([1, 3]);
    expect(dispatch).toHaveBeenCalledWith(
      'updateChatListFilters',
      expect.objectContaining({ assigneeType: 'all', whatsappScope: 'groups' })
    );
  });

  it('returns to the prior assignment tab after leaving groups', async () => {
    mounted = await mountList('/1/conversations');
    const { wrapper, router, dispatch } = mounted;

    expect(wrapper.getComponent(ChatTypeTabs).props('activeTab')).toBe('me');
    expect(conversationIds(wrapper)).toEqual([4]);

    wrapper.getComponent(ChatTypeTabs).vm.$emit('chatTabChange', 'unassigned');
    await router.push('/1/groups');
    await wrapper.setProps({ conversationType: GROUPS });

    expect(conversationIds(wrapper)).toEqual([1, 2, 3]);
    dispatch.mockClear();

    await router.push('/1/conversations');
    await wrapper.setProps({ conversationType: '' });

    expect(wrapper.getComponent(ChatTypeTabs).props('activeTab')).toBe(
      'unassigned'
    );
    expect(dispatch).toHaveBeenCalledWith(
      'updateChatListFilters',
      expect.objectContaining({
        assigneeType: 'unassigned',
        whatsappScope: 'inbox',
      })
    );
  });
});
