import { nextTick, reactive, ref } from 'vue';
import { mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { useAlert } from 'dashboard/composables';
import MessagesView from '../MessagesView.vue';
import { CONTACT_CONVERSATION_NAVIGATION } from 'dashboard/composables/useContactConversationNavigation';

vi.mock('dashboard/composables', () => ({
  useTrack: vi.fn(),
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/useCampaignHistory', () => ({
  useCampaignHistory: () => ({
    visibleCampaignHistory: ref([]),
    isCampaignHistoryLoading: ref(false),
    isCampaignHistoryReady: ref(true),
    hasMoreCampaignHistory: ref(false),
    loadCampaignHistory: vi.fn(),
  }),
}));

describe('MessagesView Ryze history', () => {
  let store;
  let currentChat;
  let dispatchMock;

  const createComponent = async (chatOverrides = {}) => {
    currentChat = reactive({
      id: 42,
      inbox_id: 1,
      ryze_history_enabled: true,
      dataFetched: true,
      allMessagesLoaded: true,
      messages: [{ id: 101, created_at: 1700000000 }],
      ...chatOverrides,
    });

    dispatchMock = vi.fn().mockResolvedValue({
      has_more: true,
      next_before: 1699999000,
      imported_count: 5,
    });

    store = createStore({
      getters: {
        getSelectedChat: () => currentChat,
        getCurrentUserID: () => 1,
        getAllMessagesLoaded: () => true,
        'globalConfig/isMetaMessageSendingDisabled': () => false,
        'inboxes/getInbox': () => () => ({ channel_type: 'Channel::Whatsapp' }),
        'inboxes/getInstagramInboxByInstagramId': () => () => null,
        'conversationTypingStatus/getUserList': () => () => [],
      },
      actions: {
        fetchAllAttachments: vi.fn(),
        markMessagesRead: vi.fn(),
        syncRyzeHistory: dispatchMock,
      },
    });

    const wrapper = mount(MessagesView, {
      global: {
        plugins: [store],
        provide: {
          [CONTACT_CONVERSATION_NAVIGATION]: {
            olderConversation: ref(null),
            newerConversation: ref(null),
            isReadingHistory: ref(false),
            latestConversation: ref(null),
            leaveReadingMode: vi.fn(),
            openConversation: vi.fn(),
            buildConversationPath: vi.fn(),
          },
        },
        mocks: {
          $t: key => key,
          $route: { query: {} },
        },
        stubs: {
          MessageList: {
            template:
              '<div class="conversation-panel"><slot name="beforeAll" /><slot name="unreadBadge" /><slot name="after" /></div>',
          },
          NextButton: {
            props: ['label', 'isLoading', 'disabled'],
            template:
              '<button :disabled="disabled" class="next-button" @click="$emit(\'click\')">{{ label }}</button>',
          },
          Banner: true,
          ReplyBox: true,
          ResizableEditorWrapper: true,
          CollapsedReplyBar: true,
          ReferralBubble: true,
          ContactConversationLink: true,
          Spinner: true,
        },
      },
    });
    await nextTick();
    return wrapper;
  };

  it('renders load older WhatsApp messages button when ryze_history_enabled is true', async () => {
    const wrapper = await createComponent();

    expect(wrapper.vm.showRyzeHistoryButton).toBe(true);
    expect(wrapper.text()).toContain('CONVERSATION.RYZE_HISTORY.LOAD_OLDER');
  });

  it('does not mark historical imports as the first unread message', async () => {
    const history = { id: 101, created_at: 42, historical_import: true };
    const incoming = { id: 102, created_at: 43 };
    const wrapper = await createComponent({
      agent_last_seen_at: null,
      messages: [history, incoming],
    });
    expect(wrapper.vm.unReadMessages).toEqual([incoming]);
    expect(wrapper.vm.readMessages).toEqual([history]);
  });

  it('does not render button when ryze_history_enabled is false or missing', async () => {
    const wrapper = await createComponent({ ryze_history_enabled: false });

    expect(wrapper.vm.showRyzeHistoryButton).toBe(false);
    expect(wrapper.text()).not.toContain(
      'CONVERSATION.RYZE_HISTORY.LOAD_OLDER'
    );
  });

  it('waits for local pagination to finish, including the empty timeline', async () => {
    const wrapper = await createComponent({
      allMessagesLoaded: false,
      messages: [],
    });
    expect(wrapper.text()).not.toContain(
      'CONVERSATION.RYZE_HISTORY.LOAD_OLDER'
    );
    currentChat.allMessagesLoaded = true;
    await nextTick();
    expect(wrapper.text()).toContain('CONVERSATION.RYZE_HISTORY.LOAD_OLDER');
  });

  it('ignores a click racing with an in-flight local load', async () => {
    const wrapper = await createComponent();
    const button = wrapper.get('button.next-button');
    wrapper.vm.isLoadingPrevious = true;
    await button.trigger('click');
    expect(dispatchMock).not.toHaveBeenCalled();
    expect(wrapper.text()).not.toContain(
      'CONVERSATION.RYZE_HISTORY.LOAD_OLDER'
    );
  });

  it('dispatches syncRyzeHistory on click and preserves state across pages', async () => {
    const wrapper = await createComponent();

    const button = wrapper
      .findAll('button')
      .find(b => b.text().includes('CONVERSATION.RYZE_HISTORY.LOAD_OLDER'));
    expect(button.exists()).toBe(true);

    await button.trigger('click');

    expect(dispatchMock).toHaveBeenCalledWith(expect.any(Object), {
      conversationId: 42,
      before: null,
    });
    expect(wrapper.vm.currentRyzeHistoryState.nextBefore).toBe(1699999000);
    expect(wrapper.vm.currentRyzeHistoryState.hasMore).toBe(true);
    expect(wrapper.vm.currentRyzeHistoryState.exhausted).toBe(false);

    // Click again to load next page using nextBefore
    await button.trigger('click');
    expect(dispatchMock).toHaveBeenLastCalledWith(expect.any(Object), {
      conversationId: 42,
      before: 1699999000,
    });
  });

  it('renders exhausted text when no more messages are available', async () => {
    const wrapper = await createComponent();
    dispatchMock.mockResolvedValueOnce({
      has_more: false,
      next_before: null,
      imported_count: 0,
    });

    const button = wrapper
      .findAll('button')
      .find(b => b.text().includes('CONVERSATION.RYZE_HISTORY.LOAD_OLDER'));
    await button.trigger('click');

    expect(wrapper.vm.showRyzeHistoryButton).toBe(false);
    expect(wrapper.vm.showRyzeHistoryExhausted).toBe(true);
    expect(wrapper.text()).toContain('CONVERSATION.RYZE_HISTORY.NO_MORE');
  });

  it('displays error alert when syncRyzeHistory rejects', async () => {
    const wrapper = await createComponent();
    dispatchMock.mockRejectedValueOnce(new Error('Network error'));

    const button = wrapper
      .findAll('button')
      .find(b => b.text().includes('CONVERSATION.RYZE_HISTORY.LOAD_OLDER'));
    await button.trigger('click');

    expect(useAlert).toHaveBeenCalledWith(
      'CONVERSATION.RYZE_HISTORY.LOAD_ERROR'
    );
    expect(wrapper.vm.ryzeHistoryLoading).toBe(false);
  });
});
