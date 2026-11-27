import axios from 'axios';
import { emitter } from 'shared/helpers/mitt';
import { createStore } from 'vuex';
import types from '../../../mutation-types';
import conversationMetadata from '../../conversationMetadata';
import { mutations } from '../../conversations';
import actions, {
  hasMessageFailedWithExternalError,
} from '../../conversations/actions';
import { dataReceived } from './testConversationResponse';
const dataToSend = {
  page: 1,
  queryData: {
    payload: [
      {
        attribute_key: 'status',
        filter_operator: 'equal_to',
        values: ['open'],
        query_operator: null,
      },
    ],
  },
};

const commit = vi.fn();
const dispatch = vi.fn();
global.axios = axios;
vi.mock('axios');

describe('#hasMessageFailedWithExternalError', () => {
  it('returns false if message is sent', () => {
    const pendingMessage = {
      status: 'sent',
      content_attributes: {},
    };
    expect(hasMessageFailedWithExternalError(pendingMessage)).toBe(false);
  });
  it('returns false if status is not failed', () => {
    const pendingMessage = {
      status: 'progress',
      content_attributes: {},
    };
    expect(hasMessageFailedWithExternalError(pendingMessage)).toBe(false);
  });

  it('returns false if status is failed but no external error', () => {
    const pendingMessage = {
      status: 'failed',
      content_attributes: {},
    };
    expect(hasMessageFailedWithExternalError(pendingMessage)).toBe(false);
  });

  it('returns true if status is failed and has external error', () => {
    const pendingMessage = {
      status: 'failed',
      content_attributes: {
        external_error: 'error',
      },
    };
    expect(hasMessageFailedWithExternalError(pendingMessage)).toBe(true);
  });
});

describe('#actions', () => {
  describe('delayed edit confirmation', () => {
    const current = { id: 5, conversation_id: 71, content: 'Original' };
    const row = {
      ...current,
      content: 'Edited',
      content_attributes: { edited: true },
      additional_attributes: { ryze_edited_at: '2026-11-26T10:00:00Z' },
    };
    let state;
    beforeEach(() => {
      vi.useFakeTimers();
      state = {
        selectedChatId: 71,
        allConversations: [{ id: 71, messages: [{ ...current }] }],
      };
    });
    afterEach(() => vi.useRealTimers());
    const refresh = () =>
      actions.refreshPendingEdit(
        { state, dispatch },
        {
          conversationId: 71,
          messageId: 5,
          content: 'Edited',
          accountUrl: '/api/v1/conversations',
        }
      );

    it('waits for the submitted version and reads only the original message', async () => {
      axios.get
        .mockResolvedValueOnce({ data: { payload: [current] } })
        .mockResolvedValueOnce({ data: { payload: [row] } });
      const done = refresh();
      await vi.runAllTimersAsync();
      await done;
      expect(axios.get).toHaveBeenCalledTimes(2);
      expect(axios.get).toHaveBeenCalledWith(
        '/api/v1/conversations/71/messages',
        {
          params: { after: 5, before: 6 },
        }
      );
      expect(dispatch).toHaveBeenCalledExactlyOnceWith('updateMessage', row);
    });

    it('does not overwrite a newer visible revision while a read is in flight', async () => {
      let resolve;
      axios.get.mockReturnValue(
        new Promise(done => {
          resolve = done;
        })
      );
      const done = refresh();
      await vi.advanceTimersByTimeAsync(4000);
      state.allConversations[0].messages[0] = {
        ...row,
        content: 'Newer',
        additional_attributes: { ryze_edited_at: '2026-11-26T11:00:00Z' },
      };
      resolve({ data: { payload: [row] } });
      await vi.runAllTimersAsync();
      await done;
      expect(dispatch).not.toHaveBeenCalled();
    });

    it('confirms two consecutive revisions without resubmitting', async () => {
      axios.get.mockResolvedValueOnce({ data: { payload: [row] } });
      const first = refresh();
      await vi.runAllTimersAsync();
      await first;
      state.allConversations[0].messages[0] = row;
      const secondRow = {
        ...row,
        content: 'Second edit',
        additional_attributes: { ryze_edited_at: '2026-11-26T10:01:00Z' },
      };
      axios.get
        .mockResolvedValueOnce({ data: { payload: [row] } })
        .mockResolvedValueOnce({ data: { payload: [secondRow] } });
      const second = actions.refreshPendingEdit(
        { state, dispatch },
        {
          conversationId: 71,
          messageId: 5,
          content: 'Second edit',
          accountUrl: '/api/v1/conversations',
        }
      );
      await vi.runAllTimersAsync();
      await second;
      expect(dispatch).toHaveBeenNthCalledWith(1, 'updateMessage', row);
      expect(dispatch).toHaveBeenNthCalledWith(2, 'updateMessage', secondRow);
      expect(axios.post).not.toHaveBeenCalled();
    });

    it('ignores an in-flight response after switching accounts', async () => {
      window.history.replaceState({}, '', '/app/accounts/1/dashboard');
      let resolve;
      axios.get.mockReturnValue(
        new Promise(done => {
          resolve = done;
        })
      );
      const done = actions.refreshPendingEdit(
        { state, dispatch },
        {
          conversationId: 71,
          messageId: 5,
          content: 'Edited',
          accountUrl: '/api/v1/accounts/1/conversations',
        }
      );
      await vi.advanceTimersByTimeAsync(4000);
      window.history.replaceState({}, '', '/app/accounts/2/dashboard');
      resolve({ data: { payload: [row] } });
      await done;
      expect(dispatch).not.toHaveBeenCalled();
      window.history.replaceState({}, '', '/');
    });

    it('stops after three unsuccessful reads', async () => {
      axios.get.mockRejectedValue(new Error('network'));
      const done = refresh();
      await vi.runAllTimersAsync();
      await done;
      expect(axios.get).toHaveBeenCalledTimes(3);
      expect(dispatch).not.toHaveBeenCalled();
    });

    it('stops after leaving the conversation', async () => {
      const done = refresh();
      state.selectedChatId = 10;
      await vi.runAllTimersAsync();
      await done;
      expect(axios.get).not.toHaveBeenCalled();
    });
  });

  describe('delayed deletion confirmation', () => {
    const row = {
      id: 5,
      conversation_id: 71,
      content_attributes: { deleted: true },
    };
    const state = { selectedChatId: 71 };
    const refresh = () =>
      actions.refreshPendingDeletion(
        { state, dispatch },
        { conversationId: 71, messageId: 5 }
      );

    beforeEach(() => {
      vi.useFakeTimers();
      state.selectedChatId = 71;
    });
    afterEach(() => vi.useRealTimers());

    it('refreshes just the original row when it becomes deleted', async () => {
      axios.get
        .mockResolvedValueOnce({
          data: { payload: [{ ...row, content_attributes: {} }] },
        })
        .mockResolvedValueOnce({ data: { payload: [row] } });
      const done = refresh();
      await vi.runAllTimersAsync();
      await done;
      expect(axios.get).toHaveBeenCalledTimes(2);
      expect(axios.get).toHaveBeenCalledWith(
        '/api/v1/conversations/71/messages',
        { params: { after: 5, before: 6 } }
      );
      expect(dispatch).toHaveBeenCalledExactlyOnceWith('updateMessage', row);
    });

    it('stops after bounded reads that cannot confirm the original', async () => {
      axios.get
        .mockRejectedValueOnce(new Error('timeout'))
        .mockResolvedValue({ data: { payload: [{ ...row, id: 6 }] } });
      const done = refresh();
      await vi.runAllTimersAsync();
      await done;
      expect(axios.get).toHaveBeenCalledTimes(3);
      expect(dispatch).not.toHaveBeenCalled();
    });

    it('stops when the agent leaves the conversation', async () => {
      const done = refresh();
      state.selectedChatId = 10;
      await vi.runAllTimersAsync();
      await done;
      expect(axios.get).not.toHaveBeenCalled();
      expect(dispatch).not.toHaveBeenCalled();
    });
  });

  describe('conversation history loading', () => {
    let store;
    let conversationA;
    let conversationB;

    beforeEach(() => {
      conversationA = { id: 42, messages: [{ id: 100 }] };
      conversationB = { id: 43, messages: [{ id: 200 }] };
      store = createStore({
        state: {
          allConversations: [conversationA, conversationB],
          selectedChatId: null,
        },
        getters: { getAutoTranslate: () => ({ enabled: false }) },
        actions,
        mutations,
        modules: {
          conversationMetadata: {
            ...conversationMetadata,
            state: { records: {} },
          },
        },
      });
    });

    it('shares pending history when switching A to B to A and keeps responses in their own conversations', async () => {
      let resolveA;
      let resolveB;
      axios.get
        .mockImplementationOnce(
          () =>
            new Promise(resolve => {
              resolveA = resolve;
            })
        )
        .mockImplementationOnce(
          () =>
            new Promise(resolve => {
              resolveB = resolve;
            })
        );

      const firstA = store.dispatch('setActiveChat', { data: conversationA });
      const firstB = store.dispatch('setActiveChat', { data: conversationB });
      const secondA = store.dispatch('setActiveChat', { data: conversationA });

      expect(axios.get).toHaveBeenCalledTimes(2);
      expect(conversationA.dataFetched).toBeUndefined();

      resolveB({ data: { meta: {}, payload: [{ id: 199 }] } });
      await firstB;
      expect(store.state.selectedChatId).toBe(42);
      expect(conversationA.messages).toEqual([{ id: 100 }]);
      expect(conversationB.messages).toEqual([{ id: 199 }, { id: 200 }]);

      resolveA({ data: { meta: {}, payload: [{ id: 99 }] } });
      await Promise.all([firstA, secondA]);
      expect(conversationA.messages).toEqual([{ id: 99 }, { id: 100 }]);
      expect(conversationA.dataFetched).toBe(true);
      expect(conversationB.dataFetched).toBe(true);
    });

    it('requires a backward page after opening an imported search result above the latest chronological ID', async () => {
      const page = Array.from({ length: 20 }, (_, i) => ({ id: 80 + i }));
      axios.get
        .mockResolvedValueOnce({ data: { meta: {}, payload: [] } })
        .mockResolvedValueOnce({ data: { meta: {}, payload: page } });

      await store.dispatch('setActiveChat', {
        data: conversationA,
        after: 500,
      });
      expect(axios.get.mock.calls.map(call => call[1].params)).toEqual([
        { after: 500, before: 100 },
        { before: 100 },
      ]);
      expect(conversationA.allMessagesLoaded).toBe(false);

      axios.get.mockResolvedValueOnce({ data: { meta: {}, payload: [] } });
      await store.dispatch('fetchPreviousMessages', {
        conversationId: 42,
        before: 80,
      });
      expect(conversationA.allMessagesLoaded).toBe(true);
    });

    it('leaves failed history unfetched and retries when the conversation is reopened', async () => {
      axios.get.mockRejectedValueOnce(new Error('Network error'));

      await store.dispatch('setActiveChat', { data: conversationA });

      expect(conversationA.dataFetched).toBeUndefined();
      expect(conversationA.messages).toEqual([{ id: 100 }]);
      expect(conversationA.allMessagesLoaded).toBe(false);

      axios.get.mockResolvedValueOnce({
        data: { meta: {}, payload: [{ id: 99 }] },
      });
      await store.dispatch('setActiveChat', { data: conversationA });

      expect(axios.get).toHaveBeenCalledTimes(2);
      expect(conversationA.messages).toEqual([{ id: 99 }, { id: 100 }]);
      expect(conversationA.dataFetched).toBe(true);
    });

    it.each(['before', 'after'])(
      'loads distinct %s cursors independently and allows a completed request again',
      async cursor => {
        let resolveHistory;
        const response = new Promise(resolve => {
          resolveHistory = resolve;
        });
        axios.get.mockReturnValue(response);
        const firstParams = { conversationId: 42, [cursor]: 90 };
        const secondParams = { conversationId: 42, [cursor]: 80 };

        const first = store.dispatch('fetchPreviousMessages', firstParams);
        const second = store.dispatch('fetchPreviousMessages', secondParams);
        expect(axios.get).toHaveBeenCalledTimes(2);

        resolveHistory({ data: { meta: {}, payload: [] } });
        await Promise.all([first, second]);
        await store.dispatch('fetchPreviousMessages', firstParams);
        expect(axios.get).toHaveBeenCalledTimes(3);
      }
    );
  });

  describe('#getConversation', () => {
    it('sends correct actions if API is success', async () => {
      axios.get.mockResolvedValue({
        data: {
          id: 1,
          labels: ['support'],
          meta: { sender: { id: 1, name: 'Contact 1' } },
        },
      });
      await actions.getConversation({ commit, dispatch }, 1);
      expect(commit.mock.calls).toEqual([
        [
          types.SET_ALL_CONVERSATION,
          [
            {
              id: 1,
              labels: ['support'],
              meta: { sender: { id: 1, name: 'Contact 1' } },
            },
          ],
        ],
        ['contacts/SET_CONTACT_ITEM', { id: 1, name: 'Contact 1' }],
      ]);
      expect(dispatch).toHaveBeenCalledWith(
        'conversationLabels/setConversationLabel',
        { id: 1, data: ['support'] }
      );
    });
    it('sends correct actions if API is error', async () => {
      axios.get.mockRejectedValue({ message: 'Incorrect header' });
      await actions.getConversation({ commit });
      expect(commit.mock.calls).toEqual([]);
    });
  });
  describe('#muteConversation', () => {
    it('sends correct actions if API is success', async () => {
      axios.get.mockResolvedValue(null);
      await actions.muteConversation({ commit }, 1);
      expect(commit.mock.calls).toEqual([[types.MUTE_CONVERSATION]]);
    });
    it('sends correct actions if API is error', async () => {
      axios.get.mockRejectedValue({ message: 'Incorrect header' });
      await actions.getConversation({ commit });
      expect(commit.mock.calls).toEqual([]);
    });
  });

  describe('#updateConversation', () => {
    it('sends setContact action and update_conversation mutation', () => {
      const conversation = {
        id: 1,
        messages: [],
        meta: { sender: { id: 1, name: 'john-doe' } },
        labels: ['support'],
      };
      actions.updateConversation(
        {
          commit,
          getters: { getConversationById: () => conversation },
          dispatch,
        },
        conversation
      );
      expect(commit.mock.calls).toEqual([
        [types.UPDATE_CONVERSATION, conversation],
      ]);
      expect(dispatch.mock.calls).toEqual([
        ['autoTranslateMessages', 1],
        [
          'conversationLabels/setConversationLabel',
          { id: 1, data: ['support'] },
        ],
        [
          'contacts/setContact',
          {
            id: 1,
            name: 'john-doe',
          },
        ],
      ]);
    });
  });

  describe('contact labels received after a partial conversation event', () => {
    const contactEvent = {
      id: 1,
      account_id: 1,
      meta: { sender: { id: 71 } },
      labels: ['support'],
    };

    it('reads the contact labels once when the event inserts an incomplete row', () => {
      const state = { allConversations: [], selectedChatId: null };
      const mockDispatch = vi.fn();
      const context = {
        commit: (type, payload) => mutations[type](state, payload),
        getters: {
          getConversationById: id =>
            state.allConversations.find(conversation => conversation.id === id),
        },
        dispatch: mockDispatch,
      };

      actions.updateConversation(context, contactEvent);
      actions.updateConversation(context, {
        ...contactEvent,
        status: 'resolved',
      });

      const fetches = mockDispatch.mock.calls.filter(
        ([action]) => action === 'fetchConversationContactLabels'
      );
      expect(fetches).toEqual([['fetchConversationContactLabels', 1]]);
    });

    it('hydrates only contact labels from the conversation response', async () => {
      const initialConversation = {
        ...contactEvent,
        status: 'open',
        messages: [{ id: 5 }],
      };
      const state = {
        allConversations: [initialConversation],
        selectedChatId: 1,
      };
      const context = {
        commit: (type, payload) => mutations[type](state, payload),
      };
      const response = {
        ...contactEvent,
        status: 'pending',
        messages: [],
        contact_labels: ['direct-insta'],
      };
      axios.get.mockResolvedValueOnce({ data: response });

      await actions.fetchConversationContactLabels(context, 1);

      expect(state.allConversations[0]).toEqual({
        ...initialConversation,
        contact_labels: ['direct-insta'],
        status: 'open',
        messages: [{ id: 5 }],
      });
    });

    it('ignores a response for a contact previously assigned to the conversation', async () => {
      const state = {
        allConversations: [{ ...contactEvent, meta: { sender: { id: 72 } } }],
      };
      const context = {
        commit: (type, payload) => mutations[type](state, payload),
      };
      axios.get.mockResolvedValueOnce({
        data: { ...contactEvent, contact_labels: ['direct-insta'] },
      });

      await actions.fetchConversationContactLabels(context, 1);

      expect(state.allConversations[0].contact_labels).toBeUndefined();
    });
  });

  describe('#addConversation', () => {
    it('doesnot send mutation if conversation is from a different inbox', () => {
      const conversation = {
        id: 1,
        messages: [],
        meta: { sender: { id: 1, name: 'john-doe' } },
        inbox_id: 2,
      };
      actions.addConversation(
        {
          commit,
          rootState: { route: { name: 'home' } },
          dispatch,
          state: { currentInbox: 1, appliedFilters: [] },
        },
        conversation
      );
      expect(commit.mock.calls).toEqual([]);
      expect(dispatch.mock.calls).toEqual([]);
    });

    it('doesnot send mutation if conversation filters are applied', () => {
      const conversation = {
        id: 1,
        messages: [],
        meta: { sender: { id: 1, name: 'john-doe' } },
        inbox_id: 1,
      };
      actions.addConversation(
        {
          commit,
          rootState: { route: { name: 'home' } },
          dispatch,
          state: { currentInbox: 1, appliedFilters: [{ id: 'random-filter' }] },
        },
        conversation
      );
      expect(commit.mock.calls).toEqual([]);
      expect(dispatch.mock.calls).toEqual([]);
    });

    it('doesnot send mutation if the view is conversation mentions', () => {
      const conversation = {
        id: 1,
        messages: [],
        meta: { sender: { id: 1, name: 'john-doe' } },
        inbox_id: 1,
      };
      actions.addConversation(
        {
          commit,
          rootState: { route: { name: 'conversation_mentions' } },
          dispatch,
          state: { currentInbox: 1, appliedFilters: [{ id: 'random-filter' }] },
        },
        conversation
      );
      expect(commit.mock.calls).toEqual([]);
      expect(dispatch.mock.calls).toEqual([]);
    });

    it('doesnot send mutation if the view is conversation folders', () => {
      const conversation = {
        id: 1,
        messages: [],
        meta: { sender: { id: 1, name: 'john-doe' } },
        inbox_id: 1,
      };
      actions.addConversation(
        {
          commit,
          rootState: { route: { name: 'folder_conversations' } },
          dispatch,
          state: { currentInbox: 1, appliedFilters: [{ id: 'random-filter' }] },
        },
        conversation
      );
      expect(commit.mock.calls).toEqual([]);
      expect(dispatch.mock.calls).toEqual([]);
    });

    it('sends correct mutations', () => {
      const conversation = {
        id: 1,
        messages: [],
        meta: { sender: { id: 1, name: 'john-doe' } },
        inbox_id: 1,
      };
      actions.addConversation(
        {
          commit,
          rootState: { route: { name: 'home' } },
          dispatch,
          state: { currentInbox: 1, appliedFilters: [] },
        },
        conversation
      );
      expect(commit.mock.calls).toEqual([
        [types.ADD_CONVERSATION, conversation],
      ]);
      expect(dispatch.mock.calls).toEqual([
        [
          'contacts/setContact',
          {
            id: 1,
            name: 'john-doe',
          },
        ],
      ]);
    });

    it('sends correct mutations if inbox filter is not available', () => {
      const conversation = {
        id: 1,
        messages: [],
        meta: { sender: { id: 1, name: 'john-doe' } },
        inbox_id: 1,
      };
      actions.addConversation(
        {
          commit,
          rootState: { route: { name: 'home' } },
          dispatch,
          state: { appliedFilters: [] },
        },
        conversation
      );
      expect(commit.mock.calls).toEqual([
        [types.ADD_CONVERSATION, conversation],
      ]);
      expect(dispatch.mock.calls).toEqual([
        [
          'contacts/setContact',
          {
            id: 1,
            name: 'john-doe',
          },
        ],
      ]);
    });
  });

  describe('#addMessage', () => {
    it('coalesces a burst from unseen groups into one authorized list refresh', async () => {
      vi.useFakeTimers();
      const localDispatch = vi.fn();
      const state = {
        allConversations: [{ id: 2 }],
        conversationFilters: { whatsappScope: 'groups' },
      };
      const rootState = { route: { name: 'whatsapp_groups' } };
      const message = {
        id: 1,
        message_type: 0,
        conversation_id: 1,
        conversation: { whatsapp_group: true },
      };

      for (let id = 1; id <= 5; id += 1) {
        actions.addMessage(
          { commit, dispatch: localDispatch, state, rootState },
          {
            ...message,
            id,
            conversation_id: 3,
          }
        );
      }
      await vi.runAllTimersAsync();

      expect(
        localDispatch.mock.calls.filter(
          ([name]) => name === 'refreshWhatsAppQueue'
        )
      ).toEqual([['refreshWhatsAppQueue']]);
      expect(localDispatch).not.toHaveBeenCalledWith('getConversation', 3);
      vi.useRealTimers();
    });

    it('keeps group messages out of the operational list refresh', async () => {
      vi.useFakeTimers();
      const state = {
        allConversations: [],
        conversationFilters: { whatsappScope: 'inbox' },
      };
      const message = {
        id: 1,
        message_type: 0,
        conversation_id: 1,
        conversation: { whatsapp_group: true },
      };

      const rootState = { route: { name: 'home' } };
      actions.addMessage({ commit, dispatch, state, rootState }, message);
      await vi.runAllTimersAsync();
      expect(dispatch).not.toHaveBeenCalledWith('refreshWhatsAppQueue');
      vi.useRealTimers();
    });

    it('sends correct mutations if message is incoming', () => {
      const message = {
        id: 1,
        message_type: 0,
        conversation_id: 1,
      };
      actions.addMessage({ commit, dispatch }, message);
      expect(commit.mock.calls).toEqual([
        [types.ADD_MESSAGE, message],
        [
          types.SET_CONVERSATION_CAN_REPLY,
          { conversationId: 1, canReply: true },
        ],
        [types.ADD_CONVERSATION_ATTACHMENTS, message],
      ]);
      expect(dispatch).toHaveBeenCalledWith('autoTranslateMessages', 1);
    });
    it('sends correct mutations if message is not an incoming message', () => {
      const message = {
        id: 1,
        message_type: 1,
        conversation_id: 1,
      };
      actions.addMessage({ commit }, message);
      expect(commit.mock.calls).toEqual([[types.ADD_MESSAGE, message]]);
    });
  });

  it('ignores a detail response started before the selected conversation changed classification', async () => {
    let finish;
    axios.get.mockReturnValueOnce(
      new Promise(resolve => {
        finish = resolve;
      })
    );
    const context = {
      commit,
      dispatch: vi.fn(),
      state: { selectedChatId: 7, allConversations: [{ id: 7, inbox_id: 2 }] },
    };
    const oldDetail = actions.getConversation(context, 7);
    await actions.refreshWhatsAppClassification(context, 2);
    finish({ data: { id: 7, whatsapp_group: true, meta: {} } });
    await oldDetail;

    expect(context.dispatch).toHaveBeenCalledWith('getConversation', 7);
    expect(commit).not.toHaveBeenCalledWith(
      types.CONFIRM_WHATSAPP_GROUP_ACCESS,
      [7]
    );
    expect(commit).not.toHaveBeenCalledWith(
      types.SET_ALL_CONVERSATION,
      expect.anything()
    );
  });

  describe('#revalidateWhatsAppGroupAccess', () => {
    it('discards a stale team-list response after revoking group access', async () => {
      const queryData = dataToSend.queryData;
      let complete;
      axios.post
        .mockReturnValueOnce(
          new Promise(resolve => {
            complete = resolve;
          })
        )
        .mockResolvedValueOnce({
          data: { payload: [], meta: { all_count: 0 } },
        });

      const context = {
        commit,
        dispatch: (action, payload) => actions[action]?.(context, payload),
        state: {
          conversationFilters: { teamId: 2 },
          authorizedWhatsAppGroups: {},
        },
        getters: { getAppliedConversationFiltersQuery: queryData },
        rootState: { route: { name: 'team_conversations' } },
      };
      const beforeChange = actions.fetchFilteredConversations(context, {
        queryData,
        page: 1,
      });
      await vi.waitFor(() => expect(axios.post).toHaveBeenCalledOnce());
      await actions.revalidateWhatsAppGroupAccess(context, 9);

      complete({
        data: {
          payload: [{ id: 9, whatsapp_group: true, meta: {} }],
          meta: {},
        },
      });
      await beforeChange;

      expect(axios.post).toHaveBeenCalledTimes(2);
      expect(commit).toHaveBeenCalledWith(types.DELETE_CONVERSATION, 9);
      expect(commit).not.toHaveBeenCalledWith(
        types.CONFIRM_WHATSAPP_GROUP_ACCESS,
        [9]
      );
    });

    it('drops a stale approved detail response on access loss and checks the current view', async () => {
      let complete;
      axios.get.mockReturnValueOnce(
        new Promise(resolve => {
          complete = resolve;
        })
      );
      const beforeChange = actions.getConversation({ commit, dispatch }, 9);
      const rootState = {
        route: {
          name: 'conversation_through_whatsapp_groups',
          params: { conversation_id: '9' },
        },
      };
      const state = { authorizedWhatsAppGroups: {}, selectedChatId: 9 };
      await actions.revalidateWhatsAppGroupAccess(
        { commit, dispatch, state, rootState },
        9
      );
      expect(commit).toHaveBeenCalledWith(types.DELETE_CONVERSATION, 9);
      expect(dispatch).toHaveBeenCalledWith('refreshWhatsAppQueue', {
        includeTransverse: true,
      });
      expect(dispatch).toHaveBeenCalledWith('getConversation', 9);

      complete({ data: { id: 9, whatsapp_group: true, meta: {} } });
      await beforeChange;
      expect(commit).not.toHaveBeenCalledWith(
        types.CONFIRM_WHATSAPP_GROUP_ACCESS,
        [9]
      );
    });
  });

  describe('#updateMessage', () => {
    it('refreshes loaded conversations sharing the same contact inbox source after terminal contact info updates', () => {
      const localCommit = vi.fn();
      const localDispatch = vi.fn();
      const message = {
        id: 1,
        conversation_id: 10,
        status: 'sent',
        content_attributes: {
          whatsapp_contact_info: {
            type: 'request',
            state: 'identity_conflict',
          },
        },
        conversation: {
          contact_inbox: { source_id: 'IN.2081978709342942' },
        },
      };
      const state = {
        allConversations: [
          { id: 10, messages: [message] },
          {
            id: 20,
            messages: [
              {
                conversation: {
                  contact_inbox: { source_id: 'IN.2081978709342942' },
                },
              },
            ],
          },
          {
            id: 30,
            messages: [
              {
                conversation: {
                  contact_inbox: { source_id: 'IN.3109889333218546' },
                },
              },
            ],
          },
        ],
      };

      actions.updateMessage(
        {
          commit: localCommit,
          dispatch: localDispatch,
          rootGetters: {},
          state,
        },
        message
      );

      expect(localCommit.mock.calls).toEqual([[types.ADD_MESSAGE, message]]);
      expect(localDispatch.mock.calls).toEqual([
        ['getConversation', 10],
        ['getConversation', 20],
      ]);
    });

    it('removes revoked message attachments from the gallery', () => {
      const localCommit = vi.fn();
      const message = {
        id: 71,
        conversation_id: 10,
        status: 'delivered',
        content: 'This message was deleted',
        content_attributes: { deleted: true },
        attachments: [],
      };

      actions.updateMessage(
        {
          commit: localCommit,
          dispatch: vi.fn(),
          state: { allConversations: [] },
        },
        message
      );

      expect(localCommit.mock.calls).toEqual([
        [types.ADD_MESSAGE, message],
        [types.DELETE_CONVERSATION_ATTACHMENTS, message],
      ]);
    });

    it('retries automatic translation when a newer Ryze edit arrives', () => {
      const localCommit = vi.fn();
      const localDispatch = vi.fn();
      const currentMessage = {
        id: 71,
        conversation_id: 10,
        content: 'Original text',
        content_attributes: {},
        additional_attributes: {},
      };
      const editedMessage = {
        ...currentMessage,
        content: 'Edited text',
        content_attributes: { edited: true },
        additional_attributes: {
          ryze_edited_at: '2026-11-25T22:00:00.000Z',
        },
      };

      actions.updateMessage(
        {
          commit: localCommit,
          dispatch: localDispatch,
          state: {
            allConversations: [{ id: 10, messages: [currentMessage] }],
            autoTranslating: { en: { 71: true }, fr: { 71: true } },
            selectedChatId: 10,
          },
        },
        editedMessage
      );

      expect(localCommit.mock.calls).toEqual([
        [types.ADD_MESSAGE, editedMessage],
        [
          types.SET_AUTO_TRANSLATING,
          { locale: 'en', messageIds: [71], translating: undefined },
        ],
        [
          types.SET_AUTO_TRANSLATING,
          { locale: 'fr', messageIds: [71], translating: undefined },
        ],
      ]);
      expect(localDispatch).toHaveBeenCalledWith('autoTranslateMessages', 10);
    });
  });

  describe('#markMessagesRead', () => {
    beforeEach(() => {
      vi.useFakeTimers();
    });

    it('sends correct mutations if api is successful', async () => {
      const lastSeen = new Date().getTime() / 1000;
      axios.post.mockResolvedValue({
        data: { id: 1, agent_last_seen_at: lastSeen },
      });
      await actions.markMessagesRead({ commit }, { id: 1 });
      vi.runAllTimers();
      expect(commit).toHaveBeenCalledTimes(1);
      expect(commit.mock.calls).toEqual([
        [types.UPDATE_MESSAGE_UNREAD_COUNT, { id: 1, lastSeen }],
      ]);
    });
    it('sends correct mutations if api is unsuccessful', async () => {
      axios.post.mockRejectedValue({ message: 'Incorrect header' });
      await actions.markMessagesRead({ commit }, { id: 1 });
      expect(commit.mock.calls).toEqual([]);
    });
  });

  describe('#markMessagesUnread', () => {
    it('sends correct mutations if API is successful', async () => {
      const lastSeen = new Date().getTime() / 1000;
      axios.post.mockResolvedValue({
        data: { id: 1, agent_last_seen_at: lastSeen, unread_count: 1 },
      });
      await actions.markMessagesUnread({ commit }, { id: 1 });
      vi.runAllTimers();
      expect(commit).toHaveBeenCalledTimes(1);
      expect(commit.mock.calls).toEqual([
        [
          types.UPDATE_MESSAGE_UNREAD_COUNT,
          { id: 1, lastSeen, unreadCount: 1 },
        ],
      ]);
    });
    it('sends correct mutations if API is unsuccessful', async () => {
      axios.post.mockRejectedValue({ message: 'Incorrect header' });
      await expect(
        actions.markMessagesUnread({ commit }, { id: 1 })
      ).rejects.toThrow(Error);
    });
  });

  describe('#sendEmailTranscript', () => {
    it('sends correct mutations if api is successful', async () => {
      axios.post.mockResolvedValue({});
      await actions.sendEmailTranscript(
        { commit },
        { conversationId: 1, email: 'testemail@example.com' }
      );
      expect(commit).toHaveBeenCalledTimes(0);
      expect(commit.mock.calls).toEqual([]);
    });
  });

  describe('#assignAgent', () => {
    it('sends correct mutations if assignment is successful', async () => {
      axios.post.mockResolvedValue({
        data: { id: 1, name: 'User' },
      });
      await actions.assignAgent(
        { dispatch },
        { conversationId: 1, agentId: 1, assigneeType: 'AgentBot' }
      );
      expect(dispatch).toHaveBeenCalledWith('setCurrentChatAssignee', {
        conversationId: 1,
        assignee: { id: 1, name: 'User' },
        assigneeType: 'AgentBot',
      });
    });
  });

  describe('#setCurrentChatAssignee', () => {
    it('sends correct mutations if assignment is successful', async () => {
      const payload = {
        conversationId: 1,
        assignee: { id: 1, name: 'User' },
        assigneeType: 'AgentBot',
      };
      await actions.setCurrentChatAssignee({ commit }, payload);
      expect(commit).toHaveBeenCalledTimes(1);
      expect(commit.mock.calls).toEqual([['ASSIGN_AGENT', payload]]);
    });
  });

  describe('#toggleStatus', () => {
    it('sends correct mutations if toggle status is successful', async () => {
      axios.post.mockResolvedValue({
        data: {
          payload: {
            conversation_id: 1,
            current_status: 'snoozed',
            snoozed_until: null,
          },
        },
      });
      await actions.toggleStatus(
        { commit },
        { conversationId: 1, status: 'snoozed' }
      );
      expect(commit).toHaveBeenCalledTimes(1);
      expect(commit.mock.calls).toEqual([
        [
          'CHANGE_CONVERSATION_STATUS',
          { conversationId: 1, status: 'snoozed', snoozedUntil: null },
        ],
      ]);
    });
  });

  describe('#assignTeam', () => {
    it('sends correct mutations if assignment is successful', async () => {
      axios.post.mockResolvedValue({
        data: { id: 1, name: 'Team' },
      });
      await actions.assignTeam({ commit }, { conversationId: 1, teamId: 1 });
      expect(commit).toHaveBeenCalledTimes(0);
      expect(commit.mock.calls).toEqual([]);
    });
  });

  describe('#setCurrentChatTeam', () => {
    it('sends correct mutations if assignment is successful', async () => {
      axios.post.mockResolvedValue({
        data: { id: 1, name: 'Team' },
      });
      await actions.setCurrentChatTeam(
        { commit },
        { team: { id: 1, name: 'Team' }, conversationId: 1 }
      );
      expect(commit).toHaveBeenCalledTimes(1);
      expect(commit.mock.calls).toEqual([
        ['ASSIGN_TEAM', { team: { id: 1, name: 'Team' }, conversationId: 1 }],
      ]);
    });
  });

  describe('#fetchFilteredConversations', () => {
    it('keeps the WhatsApp scope through advanced filter pagination and reconnect', async () => {
      axios.post.mockResolvedValue({ data: dataReceived });
      const state = {
        conversationFilters: { whatsappScope: 'groups' },
        chatSortFilter: 'last_activity_at_desc',
      };
      const queryData = { payload: [] };

      await actions.fetchFilteredConversations(
        { commit, dispatch, state },
        { queryData, page: 2 }
      );
      await actions.fetchFilteredConversations(
        { commit, dispatch, state },
        { queryData, page: 1, replaceExisting: true }
      );

      expect(axios.post).toHaveBeenNthCalledWith(
        1,
        '/api/v1/conversations/filter',
        queryData,
        expect.objectContaining({
          params: expect.objectContaining({
            page: 2,
            whatsapp_scope: 'groups',
          }),
        })
      );
      expect(axios.post).toHaveBeenNthCalledWith(
        2,
        '/api/v1/conversations/filter',
        queryData,
        expect.objectContaining({
          params: expect.objectContaining({
            page: 1,
            whatsapp_scope: 'groups',
          }),
        })
      );
    });
    it.each(['groups', 'inbox'])(
      'keeps explicit contact history unscoped from %s',
      async whatsappScope => {
        axios.post.mockResolvedValue({ data: dataReceived });
        const state = {
          conversationFilters: { whatsappScope },
          appliedFiltersWhatsAppScope: null,
        };

        await actions.fetchFilteredConversations(
          { commit, dispatch, state },
          { queryData: { payload: [] }, page: 2 }
        );

        expect(
          axios.post.mock.calls[0][2].params.whatsapp_scope
        ).toBeUndefined();
      }
    );

    it('ignores an older open-list response after applying an all-status filter', async () => {
      let resolveOpenResponse;
      axios.get.mockReturnValue(
        new Promise(resolve => {
          resolveOpenResponse = resolve;
        })
      );
      const openRequest = actions.fetchAllConversations({
        commit,
        dispatch,
        state: { conversationFilters: { status: 'open', assigneeType: 'all' } },
      });
      const filteredResponse = {
        payload: [],
        meta: { all_count: 10757 },
      };
      axios.post.mockResolvedValue({ data: filteredResponse });

      await actions.fetchFilteredConversations(
        {
          commit,
          dispatch,
          state: {
            appliedFiltersSortBy: null,
            chatSortFilter: 'last_activity_at_desc',
          },
        },
        {
          queryData: {
            payload: [
              {
                attribute_key: 'status',
                filter_operator: 'equal_to',
                values: ['all'],
              },
            ],
          },
          page: 1,
        }
      );
      resolveOpenResponse({
        data: { data: { payload: [], meta: { all_count: 30 } } },
      });
      await openRequest;

      expect(
        dispatch.mock.calls.filter(
          ([action]) => action === 'conversationStats/set'
        )
      ).toEqual([
        [
          'conversationStats/set',
          { meta: filteredResponse.meta, request: undefined },
        ],
      ]);
    });

    it('fetches filtered conversations with a mock commit', async () => {
      axios.post.mockResolvedValue({
        data: dataReceived,
      });
      await actions.fetchFilteredConversations(
        {
          commit,
          dispatch,
          state: {
            appliedFiltersSortBy: null,
            chatSortFilter: 'last_activity_at_desc',
          },
        },
        dataToSend
      );
      expect(commit).toHaveBeenCalledTimes(4);
      expect(commit.mock.calls).toEqual([
        ['SET_LIST_LOADING_STATUS'],
        ['SET_ALL_CONVERSATION', dataReceived.payload],
        ['CLEAR_LIST_LOADING_STATUS'],
        [
          `contacts/${types.SET_CONTACTS}`,
          dataReceived.payload.map(chat => chat.meta.sender),
        ],
      ]);
      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/conversations/filter',
        dataToSend.queryData,
        expect.objectContaining({
          params: {
            page: dataToSend.page,
            sort_by: 'last_activity_at_desc',
          },
        })
      );
    });

    it('clears the loading state and rethrows if the request fails', async () => {
      axios.post.mockRejectedValue(new Error('Request failed'));
      await expect(
        actions.fetchFilteredConversations(
          {
            commit,
            dispatch,
            state: {
              appliedFiltersSortBy: null,
              chatSortFilter: 'last_activity_at_desc',
            },
          },
          dataToSend
        )
      ).rejects.toThrow('Request failed');
      expect(commit.mock.calls).toEqual([
        ['SET_LIST_LOADING_STATUS'],
        ['CLEAR_LIST_LOADING_STATUS'],
      ]);
    });
  });

  describe('#setConversationFilter', () => {
    it('commits the correct mutation and sets filter state', () => {
      const filters = [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: [{ id: 'snoozed', name: 'Snoozed' }],
          query_operator: 'and',
        },
      ];
      actions.setConversationFilters({ commit }, filters);
      expect(commit.mock.calls).toEqual([
        [types.SET_CONVERSATION_FILTERS, filters],
      ]);
    });
  });

  describe('#clearConversationFilter', () => {
    it('commits the correct mutation and clears filter state', () => {
      actions.clearConversationFilters({ commit });
      expect(commit.mock.calls).toEqual([[types.CLEAR_CONVERSATION_FILTERS]]);
    });
  });

  describe('#updateConversationLastActivity', () => {
    it('sends correct action', async () => {
      await actions.updateConversationLastActivity(
        { commit },
        { conversationId: 1, lastActivityAt: 12121212 }
      );
      expect(commit.mock.calls).toEqual([
        [
          'UPDATE_CONVERSATION_LAST_ACTIVITY',
          { conversationId: 1, lastActivityAt: 12121212 },
        ],
      ]);
    });
  });

  describe('#setChatSortFilter', () => {
    it('sends correct action', async () => {
      await actions.setChatSortFilter(
        { commit },
        { data: 'sort_on_created_at' }
      );
      expect(commit.mock.calls).toEqual([
        ['CHANGE_CHAT_SORT_FILTER', { data: 'sort_on_created_at' }],
      ]);
    });
  });
});

describe('#deleteMessage', () => {
  it('sends correct actions if API is success', async () => {
    const [conversationId, messageId] = [1, 1];
    axios.delete.mockResolvedValue({
      data: { id: 1, content: 'deleted' },
    });
    await actions.deleteMessage({ commit }, { conversationId, messageId });
    expect(commit.mock.calls).toEqual([
      [types.ADD_MESSAGE, { id: 1, content: 'deleted' }],
      [types.DELETE_CONVERSATION_ATTACHMENTS, { id: 1, content: 'deleted' }],
    ]);
  });
  it('sends no actions if API is error', async () => {
    const [conversationId, messageId] = [1, 1];
    axios.delete.mockRejectedValue({ message: 'Incorrect header' });
    await expect(
      actions.deleteMessage({ commit }, { conversationId, messageId })
    ).rejects.toThrow(Error);
    expect(commit.mock.calls).toEqual([]);
  });

  describe('#deleteConversation', () => {
    it('send correct actions if API is success', async () => {
      axios.delete.mockResolvedValue({
        data: { id: 1 },
      });
      await actions.deleteConversation({ commit, dispatch }, 1);
      expect(commit.mock.calls).toEqual([[types.DELETE_CONVERSATION, 1]]);
      expect(dispatch.mock.calls).toEqual([['conversationStats/get']]);
    });

    it('send no actions if API is error', async () => {
      axios.delete.mockRejectedValue({ message: 'Incorrect header' });
      await expect(
        actions.deleteConversation({ commit, dispatch }, 1)
      ).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([]);
      expect(dispatch.mock.calls).toEqual([]);
    });
  });

  describe('#updateCustomAttributes', () => {
    it('update conversation custom attributes', async () => {
      axios.post.mockResolvedValue({
        data: { custom_attributes: { order_d: '1001' } },
      });
      await actions.updateCustomAttributes(
        { commit },
        {
          conversationId: 1,
          customAttributes: { order_d: '1001' },
        }
      );
      expect(commit.mock.calls).toEqual([
        [
          types.UPDATE_CONVERSATION_CUSTOM_ATTRIBUTES,
          {
            conversationId: 1,
            customAttributes: { order_d: '1001' },
          },
        ],
      ]);
    });
  });
});

describe('#addMentions', () => {
  it('does not send mutations if the view is not mentions', () => {
    actions.addMentions(
      { commit, dispatch, rootState: { route: { name: 'home' } } },
      { id: 1 }
    );
    expect(commit.mock.calls).toEqual([]);
    expect(dispatch.mock.calls).toEqual([]);
  });

  it('send mutations if the view is mentions', () => {
    actions.addMentions(
      {
        dispatch,
        rootState: { route: { name: 'conversation_mentions' } },
      },
      { id: 1, meta: { sender: { id: 1 } } }
    );
    expect(dispatch.mock.calls).toEqual([
      ['updateConversation', { id: 1, meta: { sender: { id: 1 } } }],
    ]);
  });

  it('#syncActiveConversationMessages', async () => {
    const conversations = [
      {
        id: 1,
        messages: [
          {
            id: 1,
            content: 'Hello',
          },
        ],
        meta: { sender: { id: 1, name: 'john-doe' } },
        inbox_id: 1,
      },
    ];
    axios.get.mockResolvedValue({
      data: {
        payload: [{ id: 2, content: 'Welcome' }],
        meta: {
          agent_last_seen_at: '2023-04-20T05:22:42.990Z',
        },
      },
    });
    await actions.syncActiveConversationMessages(
      {
        commit,
        dispatch,
        state: {
          allConversations: conversations,
          syncConversationsMessages: {
            1: 1,
          },
        },
      },
      { conversationId: 1 }
    );
    expect(dispatch).toHaveBeenCalledWith('autoTranslateMessages', 1);
    expect(commit.mock.calls).toEqual([
      [
        'conversationMetadata/SET_CONVERSATION_METADATA',
        {
          id: 1,
          data: {
            agent_last_seen_at: '2023-04-20T05:22:42.990Z',
          },
        },
      ],
      [
        'SET_MISSING_MESSAGES',
        {
          id: 1,
          data: [
            { id: 1, content: 'Hello' },
            { id: 2, content: 'Welcome' },
          ],
        },
      ],
      [
        'SET_LAST_MESSAGE_ID_FOR_SYNC_CONVERSATION',
        { conversationId: 1, messageId: null },
      ],
    ]);
  });

  describe('#fetchAllAttachments', () => {
    it('fetches all attachments', async () => {
      axios.get.mockResolvedValue({
        data: {
          payload: [
            {
              id: 1,
              message_id: 1,
              file_type: 'image',
              data_url: '',
              thumb_url: '',
            },
          ],
        },
      });
      await actions.fetchAllAttachments({ commit }, 1);
      expect(commit.mock.calls).toEqual([
        [
          types.SET_ALL_ATTACHMENTS,
          {
            id: 1,
            data: [
              {
                id: 1,
                message_id: 1,
                file_type: 'image',
                data_url: '',
                thumb_url: '',
              },
            ],
          },
        ],
      ]);
    });
  });

  describe('#setContextMenuChatId', () => {
    it('sets the context menu chat id', () => {
      actions.setContextMenuChatId({ commit }, 1);
      expect(commit.mock.calls).toEqual([[types.SET_CONTEXT_MENU_CHAT_ID, 1]]);
    });
  });

  describe('#setChatListFilters', () => {
    it('set chat list filters', () => {
      const filters = {
        inboxId: 1,
        assigneeType: 'me',
        status: 'open',
        sortBy: 'created_at',
        page: 1,
        labels: ['label'],
        teamId: 1,
        conversationType: 'mention',
      };
      actions.setChatListFilters({ commit }, filters);
      expect(commit.mock.calls).toEqual([
        [types.SET_CHAT_LIST_FILTERS, filters],
      ]);
    });
  });

  describe('#updateChatListFilters', () => {
    it('update chat list filters', () => {
      actions.updateChatListFilters({ commit }, { updatedWithin: 20 });
      expect(commit.mock.calls).toEqual([
        [types.UPDATE_CHAT_LIST_FILTERS, { updatedWithin: 20 }],
      ]);
    });
  });

  describe('#setActiveChat', () => {
    it('should commit SET_CHAT_DATA_FETCHED with conversation ID after fetch', async () => {
      const localCommit = vi.fn();
      const localDispatch = vi.fn().mockResolvedValue();
      const data = { id: 42, messages: [{ id: 100 }] };

      await actions.setActiveChat(
        { commit: localCommit, dispatch: localDispatch },
        { data, after: 99 }
      );

      expect(localCommit.mock.calls).toEqual([
        [types.SET_CURRENT_CHAT_WINDOW, data],
        [types.CLEAR_ALL_MESSAGES_LOADED, 42],
        [types.SET_CHAT_DATA_FETCHED, 42],
      ]);
      expect(localDispatch).toHaveBeenCalledWith('fetchPreviousMessages', {
        after: 99,
        before: 100,
        conversationId: 42,
      });
    });

    it('should not dispatch fetchPreviousMessages if dataFetched is already set', async () => {
      const localCommit = vi.fn();
      const localDispatch = vi.fn();
      const data = { id: 42, messages: [{ id: 100 }], dataFetched: true };

      await actions.setActiveChat(
        { commit: localCommit, dispatch: localDispatch },
        { data }
      );

      expect(localCommit.mock.calls).toEqual([
        [types.SET_CURRENT_CHAT_WINDOW, data],
      ]);
      expect(localDispatch).not.toHaveBeenCalled();
    });

    it('should commit SET_CHAT_DATA_FETCHED by ID, not mutate the data object directly (race condition fix)', async () => {
      const localCommit = vi.fn();
      const localDispatch = vi.fn().mockResolvedValue();
      const data = { id: 42, messages: [{ id: 100 }] };

      await actions.setActiveChat(
        { commit: localCommit, dispatch: localDispatch },
        { data }
      );

      // The action must NOT set dataFetched on the data object directly
      expect(data.dataFetched).toBeUndefined();

      // Instead it commits a mutation that finds the conversation by ID in the store
      expect(localCommit).toHaveBeenCalledWith(types.SET_CHAT_DATA_FETCHED, 42);
    });
  });

  describe('#getInboxCaptainAssistantById', () => {
    it('fetches inbox assistant by id', async () => {
      axios.get.mockResolvedValue({
        data: {
          id: 1,
          name: 'Assistant',
          description: 'Assistant description',
        },
      });
      await actions.getInboxCaptainAssistantById({ commit }, 1);
      expect(commit.mock.calls).toEqual([
        [
          types.SET_INBOX_CAPTAIN_ASSISTANT,
          { id: 1, name: 'Assistant', description: 'Assistant description' },
        ],
      ]);
    });
  });

  describe('#updateConversation', () => {
    it('re-checks translation once the conversation language may have changed', () => {
      const localDispatch = vi.fn();

      actions.updateConversation(
        {
          commit: vi.fn(),
          dispatch: localDispatch,
          getters: { getConversationById: () => undefined },
          rootGetters: {},
        },
        {
          id: 7,
          labels: [],
          additional_attributes: { conversation_language: 'fr' },
        }
      );

      expect(localDispatch).toHaveBeenCalledWith('autoTranslateMessages', 7);
    });
  });

  describe('#autoTranslateMessages', () => {
    const messages = [
      {
        id: 1,
        message_type: 0,
        content_type: 'text',
        content: 'Bonjour',
        content_attributes: {},
      },
      {
        id: 2,
        message_type: 0,
        content_type: 'text',
        content: 'Hello',
        content_attributes: { translations: { en: 'Hello' } },
      },
      {
        id: 3,
        message_type: 1,
        content_type: 'text',
        content: 'Hi',
        content_attributes: {},
      },
      {
        id: 4,
        message_type: 0,
        content_type: 'text',
        content: 'Merci',
        content_attributes: {},
      },
    ];
    const getters = {
      getAutoTranslate: { enabled: true, locale: 'en', sameLanguage: false },
      getSelectedChat: { id: 7, messages },
    };
    const state = { selectedChatId: 7, autoTranslating: { en: { 4: false } } };

    it('queues the incoming messages that have no translation yet and keeps them pending', async () => {
      const localCommit = vi.fn();
      axios.post.mockResolvedValue({});

      await actions.autoTranslateMessages(
        { state, commit: localCommit, getters },
        7
      );

      expect(axios.post).toHaveBeenCalledWith(
        expect.stringContaining('/conversations/7/messages/auto_translate'),
        { message_ids: [1] }
      );
      expect(localCommit.mock.calls).toEqual([
        [
          types.SET_AUTO_TRANSLATING,
          { locale: 'en', messageIds: [1], translating: true },
        ],
      ]);
    });

    it('requests bot replies, which are written in the contact language, but not agent replies', async () => {
      axios.post.mockResolvedValue({});
      const botMessages = [
        {
          id: 5,
          message_type: 1,
          content_type: 'text',
          content: 'Bonjour',
          sender: { type: 'captain_assistant' },
          content_attributes: {},
        },
        {
          id: 8,
          message_type: 1,
          content_type: 'text',
          content: 'Bonjour',
          sender: { type: 'user' },
          content_attributes: {},
        },
      ];

      await actions.autoTranslateMessages(
        {
          state: { selectedChatId: 7, autoTranslating: {} },
          commit,
          getters: {
            ...getters,
            getSelectedChat: { id: 7, messages: botMessages },
          },
        },
        7
      );

      expect(axios.post).toHaveBeenCalledWith(
        expect.stringContaining('/conversations/7/messages/auto_translate'),
        { message_ids: [5] }
      );
    });

    it('skips call bubbles and other non-text messages', async () => {
      axios.post.mockResolvedValue({});
      const chatMessages = [
        {
          id: 5,
          message_type: 0,
          content_type: 'text',
          content: 'Bonjour',
          content_attributes: {},
        },
        {
          id: 6,
          message_type: 0,
          content_type: 'voice_call',
          content: 'WhatsApp Call',
          content_attributes: {},
        },
      ];

      await actions.autoTranslateMessages(
        {
          state: { selectedChatId: 7, autoTranslating: {} },
          commit,
          getters: {
            ...getters,
            getSelectedChat: { id: 7, messages: chatMessages },
          },
        },
        7
      );

      expect(axios.post).toHaveBeenCalledWith(
        expect.stringContaining('/conversations/7/messages/auto_translate'),
        { message_ids: [5] }
      );
    });

    it('does nothing for another conversation or a disabled flag', async () => {
      await actions.autoTranslateMessages({ state, commit, getters }, 8);
      await actions.autoTranslateMessages(
        {
          state,
          commit,
          getters: {
            getAutoTranslate: { ...getters.getAutoTranslate, enabled: false },
          },
        },
        7
      );

      expect(axios.post).not.toHaveBeenCalled();
    });

    it('alerts and leaves the messages retryable when the request fails', async () => {
      const localCommit = vi.fn();
      const emit = vi.spyOn(emitter, 'emit');
      axios.post.mockRejectedValue({
        response: {
          status: 422,
          data: { error: 'You are out of Copilot credits.' },
        },
      });

      await actions.autoTranslateMessages(
        { state, commit: localCommit, getters },
        7
      );

      expect(localCommit).toHaveBeenLastCalledWith(types.SET_AUTO_TRANSLATING, {
        locale: 'en',
        messageIds: [1],
        translating: undefined,
      });
      expect(emit).toHaveBeenCalledWith('newToastMessage', {
        message: 'You are out of Copilot credits.',
        action: null,
      });
    });

    it('stays quiet when the feature is off for the account', async () => {
      const emit = vi.spyOn(emitter, 'emit');
      axios.post.mockRejectedValue({
        response: { status: 403, data: { error: 'Auto translate is off.' } },
      });

      await actions.autoTranslateMessages(
        { state, commit: vi.fn(), getters },
        7
      );

      expect(emit).not.toHaveBeenCalledWith(
        'newToastMessage',
        expect.anything()
      );
    });

    it('requests nothing in a conversation switched off', async () => {
      const localCommit = vi.fn();

      await actions.autoTranslateMessages(
        {
          state,
          commit: localCommit,
          getters: {
            ...getters,
            getAutoTranslate: {
              ...getters.getAutoTranslate,
              disabledInConversation: true,
            },
          },
        },
        7
      );

      expect(axios.post).not.toHaveBeenCalled();
      expect(localCommit).not.toHaveBeenCalled();
    });
  });

  describe('#setConversationAutoTranslate', () => {
    it('saves the switch on the conversation', async () => {
      axios.patch.mockResolvedValue({ data: {} });

      await actions.setConversationAutoTranslate(
        {},
        { conversationId: 7, disabled: true }
      );

      expect(axios.patch).toHaveBeenCalledWith(
        expect.stringContaining('/conversations/7'),
        { auto_translate_disabled: true }
      );
    });
  });

  describe('#syncRyzeHistory', () => {
    it('calls ConversationApi.syncRyzeHistory and commits SET_PREVIOUS_CONVERSATIONS when payload is present', async () => {
      const commitMock = vi.fn();
      const meta = {
        has_more: true,
        next_before: 1700000000,
        imported_count: 5,
      };
      const payload = [{ id: 10, created_at: 1699999900 }];
      axios.post.mockResolvedValue({
        data: { meta, payload },
      });

      const result = await actions.syncRyzeHistory(
        { commit: commitMock },
        { conversationId: 1, before: 1700000500 }
      );

      expect(axios.post).toHaveBeenCalledWith(
        expect.stringContaining('/conversations/1/ryze_history'),
        { before: 1700000500 },
        { timeout: 25000 }
      );
      expect(commitMock).toHaveBeenCalledWith(
        types.SET_PREVIOUS_CONVERSATIONS,
        { id: 1, data: payload }
      );
      expect(result).toEqual(meta);
    });

    it('does not commit SET_PREVIOUS_CONVERSATIONS when payload is empty', async () => {
      const commitMock = vi.fn();
      const meta = { has_more: false, next_before: null, imported_count: 0 };
      axios.post.mockResolvedValue({
        data: { meta, payload: [] },
      });

      const result = await actions.syncRyzeHistory(
        { commit: commitMock },
        { conversationId: 1 }
      );

      expect(commitMock).not.toHaveBeenCalled();
      expect(result).toEqual(meta);
    });
  });
});
