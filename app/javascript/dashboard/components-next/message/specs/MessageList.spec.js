import { flushPromises, mount } from '@vue/test-utils';
import VueDOMPurifyHTML from 'vue-dompurify-html';
import { domPurifyConfig } from 'shared/helpers/HTMLSanitizer';
import { createStore } from 'vuex';
import { withFullI18n } from 'test-i18n';
import { routeLocationKey } from 'vue-router';
import MessagesView from 'dashboard/components/widgets/conversation/MessagesView.vue';
import { createPendingMessage } from 'dashboard/helper/commons';
import actions from 'dashboard/store/modules/conversations/actions';
import MessageList from '../MessageList.vue';
import Message from '../Message.vue';
import MessageError from '../MessageError.vue';
import MessageStatus from '../MessageStatus.vue';

withFullI18n('pt_BR');

const NOW = Math.floor(Date.now() / 1000);
const CONVERSATION_ID = 71;

const mountConversation = (message, stubs = {}) => {
  const currentChat = { id: CONVERSATION_ID, inbox_id: 2, messages: [message] };
  const store = createStore({
    getters: {
      getSelectedChat: () => currentChat,
      getSelectedChatAttachments: () => [],
      'inboxes/getInbox': () => () => ({ channel_type: 'Channel::Api' }),
      'inboxes/getInboxById': () => () => ({ channel_type: 'Channel::Api' }),
      'globalConfig/get': () => ({}),
      'globalConfig/isOnChatwootCloud': () => false,
      getAutoTranslate: () => ({}),
      getMessageTranslationState: () => () => ({}),
    },
    actions: { sendMessageWithData: actions.sendMessageWithData },
    mutations: {
      ADD_MESSAGE: () => {},
      ADD_CONVERSATION_ATTACHMENTS: () => {},
    },
  });

  return mount(MessageList, {
    props: { messages: currentChat.messages, currentUserId: 1 },
    attrs: {
      onRetry: id =>
        MessagesView.methods.handleMessageRetry.call(
          { currentChat, $store: store },
          id
        ),
    },
    global: {
      plugins: [store, [VueDOMPurifyHTML, domPurifyConfig]],
      provide: { [routeLocationKey]: { query: {} } },
      stubs: {
        Avatar: true,
        AudioBubble: true,
        TextBubble: true,
        ContextMenu: true,
        ...stubs,
      },
    },
  });
};

describe('conversation messages', () => {
  const axios = vi.fn();
  axios.post = vi.fn();

  beforeEach(() => {
    vi.stubGlobal('axios', axios);
    const response = { data: { id: 100, conversation_id: CONVERSATION_ID } };
    axios.mockResolvedValue(response);
    axios.post.mockResolvedValue(response);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('renders a reaction on the original and leaves an uncorrelated message visible', async () => {
    const original = {
      id: 101,
      status: 'sent',
      message_type: 1,
      sender: { id: 1, type: 'user' },
      content: 'Original message',
      content_attributes: {},
      conversation_id: CONVERSATION_ID,
      created_at: NOW,
      attachments: [],
      ryze_reactions: { incoming: { emoji: '👍', author: 'WhatsApp contact' } },
    };
    const generic = {
      ...original,
      id: 102,
      content: '💬 Reagiu a uma mensagem',
      ryze_reactions: null,
    };
    const wrapper = mountConversation(original);
    await wrapper.setProps({ messages: [original, generic] });

    expect(wrapper.get('#message101 [role="img"]').text()).toBe('👍');
    expect(wrapper.get('#message102').find('[role="img"]').exists()).toBe(
      false
    );

    await wrapper.setProps({
      messages: [{ ...original, ryze_reactions: { incoming: null } }, generic],
    });
    expect(wrapper.get('#message101').find('[role="img"]').exists()).toBe(
      false
    );
    expect(wrapper.find('#message102').exists()).toBe(true);
    wrapper.unmount();
  });

  it.each([
    [{ can_edit_content: true, sender: { id: 1, type: 'user' } }, true],
    [{ can_edit_content: true, sender_id: 1, sender_type: 'User' }, true],
    [{ can_edit_content: true, sender: { id: 2, type: 'user' } }, false],
    [{ can_edit_content: true, sender: { id: 1, type: 'agent_bot' } }, false],
    [{ can_edit_content: false, sender: { id: 1, type: 'user' } }, false],
    [
      {
        can_edit_content: true,
        sender: { id: 1, type: 'user' },
        private: true,
      },
      false,
    ],
    [
      {
        can_edit_content: true,
        sender: { id: 1, type: 'user' },
        content_attributes: { deleted: true },
      },
      false,
    ],
  ])(
    'offers the editor only for own eligible messages %j',
    (message, canEdit) => {
      const wrapper = mountConversation({
        id: 101,
        status: 'sent',
        message_type: 1,
        content: 'Hello',
        content_attributes: {},
        conversation_id: CONVERSATION_ID,
        created_at: NOW,
        attachments: [],
        ...message,
      });

      const menu = wrapper.getComponent({ name: 'ContextMenu' });
      expect(menu.props('enabledOptions').edit).toBe(canEdit);
      expect(menu.props('hideButton')).toBe(!canEdit);
      wrapper.unmount();
    }
  );

  it('keeps the delete menu available on pilot messages after editing expires', async () => {
    const message = {
      id: 101,
      status: 'sent',
      message_type: 1,
      sender: { id: 1, type: 'user' },
      content: 'Old team text',
      content_attributes: {},
      conversation_id: CONVERSATION_ID,
      created_at: NOW - 3600,
      attachments: [],
    };
    const wrapper = mountConversation(message);
    const menu = wrapper.getComponent({ name: 'ContextMenu' });
    expect(menu.props('enabledOptions').ryzeDeleteScopes).toBe(false);
    await wrapper.setProps({
      messages: [{ ...message, ryze_delete_scopes: true }],
    });
    expect(menu.props('enabledOptions')).toMatchObject({
      ryzeDeleteScopes: true,
      edit: false,
      delete: true,
    });
    expect(menu.props('hideButton')).toBe(false);
    expect(menu.props('message').createdAt).toBe(message.created_at);
    wrapper.unmount();
  });

  it('keeps the action trigger in the bubble gutter when a sent message becomes editable', async () => {
    const message = {
      id: 101,
      status: 'sent',
      message_type: 1,
      sender: { id: 1, type: 'user' },
      content: 'Team text',
      content_attributes: {},
      conversation_id: CONVERSATION_ID,
      created_at: NOW,
      attachments: [],
    };
    const wrapper = mountConversation(message);
    const menu = wrapper.getComponent({ name: 'ContextMenu' });
    expect(menu.props('hideButton')).toBe(true);

    await wrapper.setProps({
      messages: [{ ...message, can_edit_content: true }],
    });

    expect(menu.props('hideButton')).toBe(false);
    const gutter = menu.element.parentElement;
    const avatar = wrapper.getComponent({ name: 'Avatar' });
    expect(gutter.parentElement).toBe(avatar.element.closest('.grid'));
    expect([...gutter.classList]).toEqual(
      expect.arrayContaining(['[grid-area:bubble]', 'justify-self-start'])
    );
    wrapper.unmount();
  });

  it('shows sending until Ryze confirms delivery to the channel', async () => {
    const pending = {
      id: 101,
      status: 'sent',
      message_type: 1,
      content: 'Team text',
      content_attributes: {},
      ryze_delete_scopes: true,
      ryze_delivery_pending: true,
      conversation_id: CONVERSATION_ID,
      created_at: NOW,
      attachments: [],
    };
    const wrapper = mountConversation(pending, { TextBubble: false });
    const menu = wrapper.getComponent({ name: 'ContextMenu' });
    expect(menu.props('enabledOptions').delete).toBe(false);
    expect(wrapper.getComponent(MessageStatus).props('status')).toBe(
      'progress'
    );

    await wrapper.setProps({
      messages: [
        { ...pending, ryze_delivery_pending: false, source_id: 'verified-id' },
      ],
    });
    expect(wrapper.getComponent(MessageStatus).props('status')).toBe('sent');
    expect(menu.props('enabledOptions').delete).toBe(true);
    wrapper.unmount();
  });

  it('explains uncertain Ryze delivery without offering a duplicate send', () => {
    const wrapper = mountConversation({
      id: 101,
      status: 'failed',
      message_type: 1,
      content: 'Team text with an uncertain outcome',
      content_attributes: { external_error: 'ryze_delivery_unknown' },
      conversation_id: CONVERSATION_ID,
      created_at: NOW,
      attachments: [],
    });

    const error = wrapper.getComponent(MessageError);
    expect(error.text()).toContain('Entrega sem confirmação');
    expect(error.find('button').exists()).toBe(false);
    wrapper.unmount();
  });

  it('shows Brazilian 24-hour time on the message itself', async () => {
    const wrapper = mountConversation(
      {
        id: 101,
        status: 'sent',
        message_type: 0,
        content: 'Hello',
        content_attributes: {},
        conversation_id: CONVERSATION_ID,
        created_at: new Date(2021, 10, 25, 23, 9).getTime() / 1000,
        attachments: [],
      },
      { TextBubble: false }
    );
    const { $i18n } = wrapper.vm;
    const previousLocale = $i18n.locale;
    try {
      $i18n.locale = 'pt_BR';
      await wrapper.vm.$nextTick();
      expect(wrapper.get('time').text()).toMatch(/25 de nov.*2021.*23:09/);
    } finally {
      $i18n.locale = previousLocale;
      wrapper.unmount();
    }
  });

  it.each([
    {
      name: 'an uncaptioned microphone recording',
      voiceFields: { isVoiceMessage: true },
      files: [new File(['audio'], 'recording.ogg', { type: 'audio/ogg' })],
      isPrivate: false,
      caption: null,
      voiceFlag: 'true',
      voiceIndices: [],
    },
    {
      name: 'a private mixed upload with signed file IDs',
      voiceFields: { voiceMessageAttachmentIndices: [1] },
      files: ['signed-uploaded.ogg', 'signed-recording.ogg'],
      isPrivate: true,
      caption: 'Two audio messages',
      voiceFlag: null,
      voiceIndices: ['1'],
    },
  ])(
    'resends $name after a local upload failure',
    async ({
      voiceFields,
      files,
      isPrivate,
      caption,
      voiceFlag,
      voiceIndices,
    }) => {
      const original = {
        ...createPendingMessage({
          conversationId: CONVERSATION_ID,
          message: caption,
          files,
          private: isPrivate,
          contentAttributes: { in_reply_to: 15 },
          ...voiceFields,
        }),
        status: 'failed',
      };
      const wrapper = mountConversation(original);

      await wrapper.getComponent(MessageError).get('button').trigger('click');
      await flushPromises();

      expect(axios).toHaveBeenCalledTimes(1);
      expect(axios.post).not.toHaveBeenCalled();
      const [{ url, data }] = axios.mock.calls[0];
      expect(url).toBe('/api/v1/conversations/71/messages');
      expect(data.getAll('attachments[]')).toEqual(files);
      expect(data.get('content')).toBe(caption);
      expect(data.get('content_attributes')).toBe('{"in_reply_to":15}');
      expect(data.get('private')).toBe(String(isPrivate));
      expect(data.get('is_voice_message')).toBe(voiceFlag);
      expect(data.getAll('voice_message_attachment_indices[]')).toEqual(
        voiceIndices
      );
      wrapper.unmount();
    }
  );

  it('retries an existing provider failure by its persisted message ID', async () => {
    const wrapper = mountConversation({
      id: 100,
      status: 'failed',
      message_type: 1,
      content: null,
      content_attributes: { external_error: 'delivery failed' },
      conversation_id: CONVERSATION_ID,
      created_at: NOW,
      attachments: [{ file_type: 'audio' }],
    });

    await wrapper.getComponent(MessageError).get('button').trigger('click');
    await flushPromises();

    expect(axios).not.toHaveBeenCalled();
    expect(axios.post).toHaveBeenCalledExactlyOnceWith(
      '/api/v1/conversations/71/messages/100/retry'
    );
    wrapper.unmount();
  });

  it('keeps the incoming message visible and labels its timestamp after customer deletion', async () => {
    const incoming = {
      id: 101,
      status: 'sent',
      message_type: 0,
      content: 'Edited incoming message',
      content_attributes: { edited: true },
      conversation_id: CONVERSATION_ID,
      created_at: NOW,
      attachments: [],
    };
    const wrapper = mountConversation(incoming, { TextBubble: false });
    const bubble = wrapper.getComponent(Message);
    const initialTime = bubble.get('time').text();

    expect(bubble.get('[data-bubble-name="text"]').classes()).toContain(
      'bg-n-slate-4'
    );
    expect(bubble.text()).not.toContain('Mensagem deletada pelo cliente');

    const revoked = {
      ...incoming,
      content_attributes: {
        edited: true,
        deleted: true,
        deleted_by_customer: true,
      },
    };
    await wrapper.setProps({
      messages: [revoked, { ...incoming, id: 102, content: 'Next message' }],
    });

    const updatedBubble = wrapper.getComponent(Message);
    expect(updatedBubble.vm.$.uid).toBe(bubble.vm.$.uid);
    expect(updatedBubble.text()).toContain(incoming.content);
    expect(updatedBubble.get('time').text()).toBe(initialTime);
    expect(updatedBubble.get('time + span').text()).toBe(
      'Mensagem deletada pelo cliente'
    );
    expect(updatedBubble.get('[data-bubble-name="text"]').classes()).toContain(
      'bg-n-slate-3'
    );
    const notice = updatedBubble.get('time + span');
    expect(notice.classes()).toContain('text-n-ruby-11');
    expect(
      updatedBubble.get('.prose-bubble').element.closest('.opacity-70')
    ).toBeTruthy();
    expect(notice.element.closest('.opacity-70')).toBeNull();
    expect(updatedBubble.text()).not.toContain('Editada');
    wrapper.unmount();

    const reloaded = mountConversation(revoked, { TextBubble: false });
    expect(reloaded.text()).toContain(incoming.content);
    expect(reloaded.get('time').text()).toBe(initialTime);
    expect(reloaded.get('time + span').text()).toBe(
      'Mensagem deletada pelo cliente'
    );
    reloaded.unmount();
  });

  it('does not attribute an outgoing message deletion to the customer', () => {
    const wrapper = mountConversation(
      {
        id: 101,
        status: 'sent',
        message_type: 1,
        content: 'Outgoing message',
        content_attributes: { deleted_by_customer: true },
        conversation_id: CONVERSATION_ID,
        created_at: NOW,
        attachments: [],
      },
      { TextBubble: false }
    );

    expect(wrapper.text()).not.toContain('Mensagem deletada pelo cliente');
    wrapper.unmount();
  });

  it('updates the same message bubble when the inbox marks it edited', async () => {
    const wrapper = mountConversation(
      {
        id: 101,
        status: 'sent',
        message_type: 0,
        content: 'Incoming message',
        content_attributes: {},
        conversation_id: CONVERSATION_ID,
        created_at: NOW,
        attachments: [],
      },
      { TextBubble: false }
    );
    const messageBubble = wrapper.getComponent(Message);
    const originalBubbleInstance = messageBubble.vm.$.uid;

    expect(messageBubble.props().content).toBe('Incoming message');
    expect(wrapper.text()).not.toContain('Editada');

    await wrapper.setProps({
      messages: [
        {
          id: 101,
          status: 'sent',
          message_type: 0,
          content: 'Edited incoming message',
          content_attributes: { edited: true },
          conversation_id: CONVERSATION_ID,
          created_at: NOW,
          attachments: [],
        },
      ],
    });
    const editedBubble = wrapper.getComponent(Message);

    expect(editedBubble.vm.$.uid).toBe(originalBubbleInstance);
    expect(editedBubble.props().content).toBe('Edited incoming message');
    const editedLabel = editedBubble.get('time + span');
    expect(editedLabel.text()).toBe('Editada');
    expect(editedLabel.classes()).toEqual(
      expect.arrayContaining(['text-n-blue-12', 'dark:text-n-blue-11'])
    );

    await wrapper.setProps({
      messages: [
        {
          id: 101,
          status: 'sent',
          message_type: 0,
          content: 'This message was deleted',
          content_attributes: { edited: true, deleted: true },
          conversation_id: CONVERSATION_ID,
          created_at: NOW,
          attachments: [],
        },
      ],
    });
    const deletedBubble = wrapper.getComponent(Message);

    expect(deletedBubble.vm.$.uid).toBe(originalBubbleInstance);
    expect(deletedBubble.props().content).toBe('This message was deleted');
    expect(wrapper.text()).not.toContain('Editada');
    expect(wrapper.text()).not.toContain('Mensagem deletada pelo cliente');

    wrapper.unmount();
  });
});
