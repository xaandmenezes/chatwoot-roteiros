import types from '../../mutation-types';
import getters, { getSelectedChatConversation } from './getters';
import actions from './actions';
import { findPendingMessageIndex, isOlderRyzeRevision } from './helpers';
import { MESSAGE_STATUS } from 'shared/constants/messages';
import wootConstants from 'dashboard/constants/globals';
import { BUS_EVENTS } from '../../../../shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';
import { CONTENT_TYPES } from 'dashboard/components-next/message/constants.js';

const state = {
  allConversations: [],
  authorizedWhatsAppGroups: {},
  attachments: {},
  listLoadingStatus: true,
  chatStatusFilter: wootConstants.STATUS_TYPE.OPEN,
  chatSortFilter: wootConstants.SORT_BY_TYPE.LATEST,
  currentInbox: null,
  selectedChatId: null,
  appliedFilters: [],
  appliedFiltersSortBy: null,
  appliedFiltersWhatsAppScope: undefined,
  contextMenuChatId: null,
  conversationParticipants: [],
  conversationLastSeen: null,
  syncConversationsMessages: {},
  conversationFilters: {},
  copilotAssistant: {},
  autoTranslating: {},
  removedRyzeEchoIds: {},
};

const getConversationById = _state => conversationId => {
  return _state.allConversations.find(c => c.id === conversationId);
};

const setMissingContactLabels = (chat, accountId, contactId, labels) => {
  if (
    chat &&
    Array.isArray(labels) &&
    chat.contact_labels === undefined &&
    chat.account_id === accountId &&
    chat.meta?.sender?.id === contactId
  ) {
    chat.contact_labels = labels;
  }
};

const preserveConversationMessageState = (
  conversation,
  existingConversation
) => ({
  ...conversation,
  allMessagesLoaded: existingConversation.allMessagesLoaded,
  messages: existingConversation.messages,
  dataFetched: existingConversation.dataFetched,
});

const preserveNewerReactions = (message, previous) => {
  const reactions = previous?.ryze_reactions;
  if (
    previous?.id === message.id &&
    reactions?.revision > (message.ryze_reactions?.revision ?? 0)
  ) {
    return { ...message, ryze_reactions: reactions };
  }
  return message;
};

// mutations
export const mutations = {
  [types.SET_ALL_CONVERSATION](_state, conversationList) {
    const newAllConversations = [..._state.allConversations];
    conversationList.forEach(conversation => {
      const indexInCurrentList = newAllConversations.findIndex(
        c => c.id === conversation.id
      );
      if (indexInCurrentList < 0) {
        newAllConversations.push(conversation);
      } else if (conversation.id !== _state.selectedChatId) {
        // If the conversation is already in the list, replace it
        // Added this to fix the issue of the conversation not being updated
        // When reconnecting to the websocket. If the selectedChatId is not the same as
        // the conversation.id in the store, replace the existing conversation with the new one
        newAllConversations[indexInCurrentList] = conversation;
      } else {
        // If the conversation is already in the list and selectedChatId is the same,
        // replace all data except the messages array, attachments, dataFetched, allMessagesLoaded
        const existingConversation = newAllConversations[indexInCurrentList];
        newAllConversations[indexInCurrentList] =
          preserveConversationMessageState(conversation, existingConversation);
      }
    });
    _state.allConversations = newAllConversations;
  },
  [types.REPLACE_CONVERSATION_LIST](_state, conversationList) {
    _state.authorizedWhatsAppGroups = {};
    const selectedConversation = getConversationById(_state)(
      _state.selectedChatId
    );
    const replacementList = [...conversationList];
    if (selectedConversation) {
      const selectedConversationIndex = replacementList.findIndex(
        conversation => conversation.id === selectedConversation.id
      );
      if (selectedConversationIndex === -1) {
        replacementList.push(selectedConversation);
      } else {
        replacementList[selectedConversationIndex] =
          preserveConversationMessageState(
            replacementList[selectedConversationIndex],
            selectedConversation
          );
      }
    }
    _state.allConversations = replacementList;
  },
  [types.EMPTY_ALL_CONVERSATION](_state) {
    _state.allConversations = [];
    _state.authorizedWhatsAppGroups = {};
    _state.selectedChatId = null;
    _state.removedRyzeEchoIds = {};
  },
  [types.SET_ALL_MESSAGES_LOADED](_state, conversationId) {
    const chat = getConversationById(_state)(conversationId);
    if (chat) {
      chat.allMessagesLoaded = true;
    }
  },

  [types.CLEAR_ALL_MESSAGES_LOADED](_state, conversationId) {
    const chat = getConversationById(_state)(conversationId);
    if (chat) {
      chat.allMessagesLoaded = false;
    }
  },
  [types.CLEAR_CURRENT_CHAT_WINDOW](_state) {
    _state.selectedChatId = null;
  },

  [types.SET_PREVIOUS_CONVERSATIONS](_state, { id, data }) {
    if (data.length) {
      const [chat] = _state.allConversations.filter(c => c.id === id);
      const messageIds = new Set(chat.messages.map(message => message.id));
      const newMessages = data.filter(message => {
        if (
          messageIds.has(message.id) ||
          _state.removedRyzeEchoIds?.[message.id]
        ) {
          return false;
        }
        messageIds.add(message.id);
        return true;
      });
      chat.messages.unshift(...newMessages);
      chat.messages.sort((a, b) => a.created_at - b.created_at || a.id - b.id);
    }
  },
  [types.SET_ALL_ATTACHMENTS](_state, { id, data }) {
    _state.attachments[id] = [...data];
  },
  [types.SET_MISSING_MESSAGES](_state, { id, data }) {
    const [chat] = _state.allConversations.filter(c => c.id === id);
    if (!chat) return;
    const remaining = data.filter(
      message => !_state.removedRyzeEchoIds?.[message.id]
    );
    const previousMessages = new Map(
      (chat.messages ?? [])
        .filter(message => message.ryze_reactions)
        .map(message => [message.id, message])
    );
    chat.messages = previousMessages.size
      ? remaining.map(message =>
          preserveNewerReactions(message, previousMessages.get(message.id))
        )
      : remaining;
  },

  [types.SET_CHAT_DATA_FETCHED](_state, conversationId) {
    const chat = getConversationById(_state)(conversationId);
    if (chat) {
      chat.dataFetched = true;
    }
  },

  [types.SET_CURRENT_CHAT_WINDOW](_state, activeChat) {
    if (activeChat) {
      _state.selectedChatId = activeChat.id;
    }
  },

  [types.ASSIGN_AGENT](_state, { conversationId, assignee, assigneeType }) {
    const chat = getConversationById(_state)(conversationId);
    if (chat) {
      chat.meta.assignee = assignee;
      const inferredAssigneeType = assignee ? 'User' : null;
      chat.meta.assignee_type =
        assigneeType === undefined ? inferredAssigneeType : assigneeType;
    }
  },

  [types.ASSIGN_TEAM](_state, { team, conversationId }) {
    const [chat] = _state.allConversations.filter(c => c.id === conversationId);
    chat.meta.team = team;
  },

  [types.UPDATE_CONVERSATION_LAST_ACTIVITY](
    _state,
    { lastActivityAt, conversationId }
  ) {
    const [chat] = _state.allConversations.filter(c => c.id === conversationId);
    if (chat) {
      chat.last_activity_at = lastActivityAt;
    }
  },
  [types.ASSIGN_PRIORITY](_state, { priority, conversationId }) {
    const [chat] = _state.allConversations.filter(c => c.id === conversationId);
    chat.priority = priority;
  },

  [types.UPDATE_CONVERSATION_CUSTOM_ATTRIBUTES](
    _state,
    { conversationId, customAttributes }
  ) {
    const conversation = _state.allConversations.find(
      c => c.id === conversationId
    );
    if (conversation) {
      conversation.custom_attributes = {
        ...conversation.custom_attributes,
        ...customAttributes,
      };
    }
  },

  [types.CHANGE_CONVERSATION_STATUS](
    _state,
    { conversationId, status, snoozedUntil }
  ) {
    const conversation =
      getters.getConversationById(_state)(conversationId) || {};
    conversation.snoozed_until = snoozedUntil;
    conversation.status = status;
  },

  [types.MUTE_CONVERSATION](_state) {
    const [chat] = getSelectedChatConversation(_state);
    chat.muted = true;
  },

  [types.UNMUTE_CONVERSATION](_state) {
    const [chat] = getSelectedChatConversation(_state);
    chat.muted = false;
  },

  [types.ADD_CONVERSATION_ATTACHMENTS](_state, message) {
    // early return if the message has not been sent, or has no attachments
    if (
      message.status !== MESSAGE_STATUS.SENT ||
      !message.attachments?.length
    ) {
      return;
    }

    const id = message.conversation_id;
    const [conversation] = getSelectedChatConversation({
      allConversations: _state.allConversations,
      selectedChatId: id,
    });
    const currentMessage = conversation?.messages?.find(
      item => item.id === message.id
    );
    if (
      currentMessage?.content_attributes?.deleted ||
      (currentMessage && isOlderRyzeRevision(currentMessage, message))
    ) {
      return;
    }

    const existingAttachments = _state.attachments[id] || [];

    const attachmentsToAdd = message.attachments.filter(attachment => {
      // if the attachment is not already in the store, add it
      // this is to prevent duplicates
      return !existingAttachments.some(
        existingAttachment => existingAttachment.id === attachment.id
      );
    });

    // replace the attachments in the store
    _state.attachments[id] = [...existingAttachments, ...attachmentsToAdd];
  },

  [types.DELETE_CONVERSATION_ATTACHMENTS](_state, message) {
    const { conversation_id: id } = message;
    const existingAttachments = _state.attachments[id] || [];
    if (!existingAttachments.length) return;

    _state.attachments[id] = existingAttachments.filter(attachment => {
      return attachment.message_id !== message.id;
    });
  },

  [types.ADD_MESSAGE](
    { allConversations, selectedChatId, removedRyzeEchoIds },
    message
  ) {
    if (removedRyzeEchoIds?.[message.id]) return;

    const { conversation_id: conversationId } = message;
    const [chat] = getSelectedChatConversation({
      allConversations,
      selectedChatId: conversationId,
    });
    if (!chat) return;

    const replacedMessageId =
      message.additional_attributes?.ryze_replaced_message_id;
    if (replacedMessageId) {
      chat.messages = chat.messages.filter(
        existing =>
          existing.id !== replacedMessageId ||
          existing.source_id !== message.source_id ||
          !existing.additional_attributes?.ryze_native_bridge_mirror
      );
    }
    if (
      message.additional_attributes?.ryze_native_bridge_mirror &&
      chat.messages.some(
        existing =>
          existing.source_id === message.source_id &&
          existing.additional_attributes?.ryze_replaced_message_id ===
            message.id
      )
    ) {
      return;
    }

    const pendingMessageIndex = findPendingMessageIndex(chat, message);
    if (pendingMessageIndex !== -1) {
      const existingMessage = chat.messages[pendingMessageIndex];
      if (
        existingMessage.id === message.id &&
        !message.content_attributes?.deleted &&
        (existingMessage.content_attributes?.deleted ||
          isOlderRyzeRevision(existingMessage, message) ||
          (existingMessage.additional_attributes?.ryze_outbound_message_id &&
            !message.source_id))
      ) {
        return;
      }

      chat.messages[pendingMessageIndex] = preserveNewerReactions(
        message,
        existingMessage
      );
    } else {
      chat.messages.push(message);
      chat.timestamp = message.created_at;
      const { conversation: { unread_count: unreadCount = 0 } = {} } = message;
      chat.unread_count = unreadCount;
      if (selectedChatId === conversationId) {
        emitter.emit(BUS_EVENTS.SCROLL_TO_MESSAGE);
      }
    }
  },
  [types.UPDATE_MESSAGE_RYZE_REACTIONS](_state, payload) {
    const chat = getConversationById(_state)(payload.conversation_id);
    const message = chat?.messages?.find(item => item.id === payload.id);
    const reactions = payload.ryze_reactions;
    if (
      message &&
      reactions?.revision > (message.ryze_reactions?.revision ?? 0)
    ) {
      message.ryze_reactions = reactions;
    }
  },
  [types.REMOVE_RYZE_REACTION_ECHO](_state, payload) {
    const {
      id,
      conversation_id: conversationId,
      last_non_activity_message: preview,
    } = payload;
    _state.removedRyzeEchoIds ??= {};
    _state.removedRyzeEchoIds[id] = true;

    const chat = getConversationById(_state)(conversationId);
    if (!chat) return;

    chat.messages = chat.messages.filter(message => message.id !== id);
    if (chat.last_non_activity_message?.id === id) {
      chat.last_non_activity_message = _state.removedRyzeEchoIds[preview?.id]
        ? null
        : preview;
    }
    if (chat.last_activity_at <= payload.echo_created_at) {
      chat.last_activity_at = payload.last_activity_at;
    }
    if (chat.timestamp <= payload.echo_created_at) {
      chat.timestamp = payload.last_activity_at;
    }
  },

  [types.SET_AUTO_TRANSLATING](_state, { locale, messageIds, translating }) {
    _state.autoTranslating[locale] ??= {};
    messageIds.forEach(id => {
      _state.autoTranslating[locale][id] = translating;
    });
  },

  [types.ADD_CONVERSATION](_state, conversation) {
    const existing = getConversationById(_state)(conversation.id);
    if (!existing) {
      _state.allConversations.push(conversation);
    } else {
      setMissingContactLabels(
        existing,
        conversation.account_id,
        conversation.meta?.sender?.id,
        conversation.contact_labels
      );
    }
  },

  [types.CONFIRM_WHATSAPP_GROUP_ACCESS](_state, ids) {
    ids.forEach(id => {
      _state.authorizedWhatsAppGroups[id] = true;
    });
  },

  [types.DELETE_CONVERSATION](_state, conversationId) {
    delete _state.authorizedWhatsAppGroups?.[conversationId];
    _state.allConversations = _state.allConversations.filter(
      c => c.id !== conversationId
    );
  },

  [types.UPDATE_CONVERSATION](_state, conversation) {
    const { allConversations } = _state;
    const index = allConversations.findIndex(c => c.id === conversation.id);

    if (index > -1) {
      const selectedConversation = allConversations[index];

      // ignore out of order events
      if (conversation.updated_at < selectedConversation.updated_at) {
        return;
      }

      const { messages, ...updates } = conversation;
      const updatedConversation = { ...selectedConversation, ...updates };
      const contactId = updates.meta?.sender?.id;
      if (
        contactId &&
        contactId !== selectedConversation.meta?.sender?.id &&
        updates.contact_labels === undefined
      ) {
        delete updatedConversation.contact_labels;
      }
      allConversations[index] = updatedConversation;
      if (_state.selectedChatId === conversation.id) {
        emitter.emit(BUS_EVENTS.SCROLL_TO_MESSAGE);
      }
    } else {
      const { conversationType } = _state.conversationFilters || {};
      const { MENTION, PARTICIPATING } = wootConstants.CONVERSATION_TYPE;
      if (![MENTION, PARTICIPATING].includes(conversationType)) {
        _state.allConversations.push(conversation);
      }
    }
  },

  [types.SET_LIST_LOADING_STATUS](_state) {
    _state.listLoadingStatus = true;
  },

  [types.CLEAR_LIST_LOADING_STATUS](_state) {
    _state.listLoadingStatus = false;
  },

  [types.UPDATE_MESSAGE_UNREAD_COUNT](
    _state,
    { id, lastSeen, unreadCount = 0 }
  ) {
    const [chat] = _state.allConversations.filter(c => c.id === id);
    if (chat) {
      chat.agent_last_seen_at = lastSeen;
      chat.unread_count = unreadCount;
    }
  },
  [types.CHANGE_CHAT_STATUS_FILTER](_state, data) {
    _state.chatStatusFilter = data;
  },

  [types.CHANGE_CHAT_SORT_FILTER](_state, data) {
    _state.chatSortFilter = data;
  },

  // Update assignee on action cable message
  [types.UPDATE_ASSIGNEE](_state, payload) {
    const chat = getConversationById(_state)(payload.id);
    if (chat) {
      chat.meta.assignee = payload.assignee;
    }
  },

  [types.UPDATE_CONVERSATION_CONTACT](
    _state,
    { conversationId, contactLabels, ...sender }
  ) {
    const chat = getConversationById(_state)(conversationId);
    if (!chat) return;

    if (contactLabels !== undefined) {
      chat.contact_labels = contactLabels;
    } else if (sender.id && sender.id !== chat.meta.sender?.id) {
      delete chat.contact_labels;
    }
    chat.meta.sender = sender;
  },

  [types.SET_CONVERSATION_CONTACT_LABELS](
    _state,
    { conversationId, accountId, contactId, labels }
  ) {
    const chat = getConversationById(_state)(conversationId);
    setMissingContactLabels(chat, accountId, contactId, labels);
  },

  [types.UPDATE_MESSAGE_CALL_STATUS](
    _state,
    { conversationId, callStatus, callSid }
  ) {
    const chat = getConversationById(_state)(conversationId);
    if (!chat) return;

    const message = (chat.messages || []).find(
      m =>
        m.content_type === CONTENT_TYPES.VOICE_CALL &&
        m.call?.provider_call_id === callSid
    );
    if (!message?.call) return;

    message.call = { ...message.call, status: callStatus };
  },

  [types.SET_ACTIVE_INBOX](_state, inboxId) {
    _state.currentInbox = inboxId ? parseInt(inboxId, 10) : null;
  },

  [types.SET_CONVERSATION_CAN_REPLY](_state, { conversationId, canReply }) {
    const [chat] = _state.allConversations.filter(c => c.id === conversationId);
    if (chat) {
      chat.can_reply = canReply;
    }
  },

  [types.CLEAR_CONTACT_CONVERSATIONS](_state, contactId) {
    const chats = _state.allConversations.filter(
      c => c.meta.sender.id !== contactId
    );
    _state.allConversations = chats;
  },

  [types.SET_CONVERSATION_FILTERS](_state, data) {
    _state.appliedFilters = data;
  },

  [types.SET_CONVERSATION_FILTERS_SORT](_state, sortBy) {
    _state.appliedFiltersSortBy = sortBy;
  },

  [types.SET_CONVERSATION_FILTERS_WHATSAPP_SCOPE](_state, scope) {
    _state.appliedFiltersWhatsAppScope = scope;
  },
  [types.CLEAR_CONVERSATION_FILTERS](_state) {
    _state.appliedFiltersWhatsAppScope = undefined;
    _state.appliedFilters = [];
    _state.appliedFiltersSortBy = null;
  },

  [types.SET_LAST_MESSAGE_ID_IN_SYNC_CONVERSATION](
    _state,
    { conversationId, messageId }
  ) {
    _state.syncConversationsMessages[conversationId] = messageId;
  },

  [types.SET_CONTEXT_MENU_CHAT_ID](_state, chatId) {
    _state.contextMenuChatId = chatId;
  },

  [types.SET_CHAT_LIST_FILTERS](_state, data) {
    _state.conversationFilters = data;
  },
  [types.UPDATE_CHAT_LIST_FILTERS](_state, data) {
    _state.conversationFilters = { ..._state.conversationFilters, ...data };
  },
  [types.SET_INBOX_CAPTAIN_ASSISTANT](_state, data) {
    _state.copilotAssistant = data.assistant;
  },
};

export default {
  state,
  getters,
  actions,
  mutations,
};
