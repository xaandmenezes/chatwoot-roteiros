import { throwErrorMessage } from 'dashboard/store/utils/api';
import ConversationApi from '../../../../api/inbox/conversation';
import MessageApi from '../../../../api/inbox/message';
import mutationTypes from '../../../mutation-types';

// The Ryze bridge shares an agent's socket token, so that agent's dashboard
// must read a delayed deletion from history instead of relying on the socket.
const DELETION_REFRESH_DELAYS_MS = [4000, 8000, 12000];

export default {
  async refreshPendingDeletion(
    { state, dispatch },
    { conversationId, messageId }
  ) {
    const accountUrl = MessageApi.url;
    const originalId = Number(messageId);
    const viewingConversation = () =>
      MessageApi.url === accountUrl &&
      Number(state.selectedChatId) === Number(conversationId);

    const readAfter = async attempt => {
      await new Promise(resolve => {
        setTimeout(resolve, DELETION_REFRESH_DELAYS_MS[attempt]);
      });
      if (!viewingConversation()) return;

      try {
        const { data } = await MessageApi.getPreviousMessages({
          conversationId,
          after: originalId,
          before: originalId + 1,
        });
        const deleted = data.payload.find(
          row => row.id === originalId && row.content_attributes?.deleted
        );
        if (deleted && viewingConversation()) {
          dispatch('updateMessage', deleted);
          return;
        }
      } catch {
        // A failed history read leaves the displayed message intact.
      }
      if (attempt + 1 < DELETION_REFRESH_DELAYS_MS.length) {
        await readAfter(attempt + 1);
      }
    };
    await readAfter(0);
  },

  markMessagesRead: async ({ commit }, data) => {
    try {
      const {
        data: { id, agent_last_seen_at: lastSeen },
      } = await ConversationApi.markMessageRead(data);
      setTimeout(
        () =>
          commit(mutationTypes.UPDATE_MESSAGE_UNREAD_COUNT, { id, lastSeen }),
        4000
      );
    } catch (error) {
      // Handle error
    }
  },

  markMessagesUnread: async ({ commit }, { id }) => {
    try {
      const {
        data: { agent_last_seen_at: lastSeen, unread_count: unreadCount },
      } = await ConversationApi.markMessagesUnread({ id });
      commit(mutationTypes.UPDATE_MESSAGE_UNREAD_COUNT, {
        id,
        lastSeen,
        unreadCount,
      });
    } catch (error) {
      throwErrorMessage(error);
    }
  },
};
