import { flushPromises, mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { routeLocationKey } from 'vue-router';
import MessagesView from 'dashboard/components/widgets/conversation/MessagesView.vue';
import { createPendingMessage } from 'dashboard/helper/commons';
import actions from 'dashboard/store/modules/conversations/actions';
import MessageList from '../MessageList.vue';
import MessageError from '../MessageError.vue';

const NOW = Math.floor(Date.now() / 1000);
const CONVERSATION_ID = 71;

const mountConversation = message => {
  const currentChat = { id: CONVERSATION_ID, messages: [message] };
  const store = createStore({
    getters: {
      getSelectedChat: () => currentChat,
      getSelectedChatAttachments: () => [],
      'inboxes/getInbox': () => () => ({ channel_type: 'Channel::Api' }),
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
      plugins: [store],
      provide: { [routeLocationKey]: { query: {} } },
      stubs: {
        Avatar: true,
        AudioBubble: true,
        TextBubble: true,
        ContextMenu: true,
      },
    },
  });
};

describe('retrying audio in a conversation', () => {
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
});
