import { flushPromises, shallowMount } from '@vue/test-utils';
import { REPLY_EDITOR_MODES } from 'dashboard/components/widgets/WootWriter/constants';
import { nextTick, reactive } from 'vue';
import ConversationApi from 'dashboard/api/conversations';
import { createStore } from 'vuex';
import ReplyBox from '../ReplyBox.vue';
import WhatsappTemplates from '../WhatsappTemplates/Modal.vue';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { appendSignature } from 'dashboard/helper/editorHelper';

const CHANNELS = [
  { name: 'WhatsApp Cloud', inbox: { channel_type: 'Channel::Whatsapp' } },
  {
    name: 'Twilio WhatsApp',
    inbox: { channel_type: 'Channel::TwilioSms', medium: 'whatsapp' },
  },
  { name: 'API', inbox: { channel_type: 'Channel::Api' } },
  { name: 'Instagram', inbox: { channel_type: 'Channel::Instagram' } },
  { name: 'TikTok', inbox: { channel_type: 'Channel::Tiktok' } },
  { name: 'Facebook', inbox: { channel_type: 'Channel::FacebookPage' } },
  { name: 'Line', inbox: { channel_type: 'Channel::Line' } },
  { name: 'Telegram', inbox: { channel_type: 'Channel::Telegram' } },
  { name: 'Email', inbox: { channel_type: 'Channel::Email' } },
  { name: 'Web widget', inbox: { channel_type: 'Channel::WebWidget' } },
];

const exemptFromMessagingWindow = name =>
  ['WhatsApp Cloud', 'Twilio WhatsApp', 'API'].includes(name);

const REPLIABLE = {
  id: 1,
  inbox_id: 1,
  can_reply: true,
  status: 'open',
  meta: { sender: { id: 2 } },
  messages: [],
};

const buildStore = ({
  inbox,
  chat,
  templates,
  drafts = {},
  inboxes,
  isMetaMessageSendingDisabled = false,
  uiSettings = {},
  signature = '',
  globalConfig = {},
}) =>
  createStore({
    state: {
      chat: { ...REPLIABLE, ...chat },
      replyEditorMode: REPLY_EDITOR_MODES.REPLY,
      drafts: { ...drafts },
    },
    mutations: {
      selectChat: (s, c) => {
        s.chat = c;
      },
      setReplyEditorMode: (s, mode) => {
        s.replyEditorMode = mode;
      },
      setDraft: (s, { key, message }) => {
        s.drafts = { ...s.drafts, [key]: message };
      },
    },
    actions: {
      'draftMessages/setReplyEditorMode': ({ commit }, { mode }) =>
        commit('setReplyEditorMode', mode),
      'draftMessages/set': ({ commit }, payload) => commit('setDraft', payload),
    },
    getters: {
      getSelectedChat: s => s.chat,
      getCurrentUser: () => ({ id: 7, name: 'Agent', accounts: [] }),
      getCurrentAccountId: () => 1,
      getMessageSignature: () => signature,
      getUISettings: () => uiSettings,
      getLastEmailInSelectedChat: () => null,
      'globalConfig/get': () => globalConfig,
      'globalConfig/isMetaMessageSendingDisabled': () =>
        isMetaMessageSendingDisabled,
      'inboxes/getInbox': () => inboxId => ({
        id: inboxId,
        ...(inboxes?.[inboxId] || inbox),
      }),
      'inboxes/getWhatsAppTemplates': () => () => templates,
      'contacts/getContact': () => () => ({}),
      'draftMessages/get': s => key => s.drafts[key] || '',
      'draftMessages/getReplyEditorMode': s => s.replyEditorMode,
      'accounts/isFeatureEnabledonAccount': () => () => false,
      'accounts/getAccount': () => () => ({}),
      'portals/allPortals': () => [],
      'integrations/getUIFlags': () => ({ isFetching: false }),
    },
  });

const mountWith = ({
  inbox,
  chat,
  templates = [{ name: 'greeting' }],
  drafts,
  inboxes,
  isMetaMessageSendingDisabled,
  uiSettings,
  signature,
  globalConfig,
  route,
}) => {
  const store = buildStore({
    inbox,
    chat,
    templates,
    drafts,
    inboxes,
    isMetaMessageSendingDisabled,
    uiSettings,
    signature,
    globalConfig,
  });
  const wrapper = shallowMount(ReplyBox, {
    global: {
      plugins: [store],
      mocks: { $t: key => key, $route: route },
      // The bottom panel sits inside a <Transition>, which shallowMount stubs
      // without rendering its children.
      stubs: { transition: false },
    },
  });
  return { wrapper, store };
};

const topPanel = wrapper =>
  wrapper.findComponent({ name: 'ReplyTopPanel' }).props();
const bottomPanel = wrapper =>
  wrapper.findComponent({ name: 'ReplyBottomPanel' }).props();
const editor = wrapper =>
  wrapper.findComponent({ name: 'WootMessageEditor' }).props();

describe('ReplyBox', () => {
  it('wires public typing and recording and clears the original target on note or navigation', async () => {
    const publish = vi
      .spyOn(ConversationApi, 'publishRyzePresence')
      .mockResolvedValue({});
    const route = reactive({
      params: { accountId: '1', conversation_id: '1' },
    });
    const { wrapper } = mountWith({
      inbox: { channel_type: 'Channel::Api' },
      chat: { account_id: 1, ryze_presence_enabled: true },
      route,
    });
    try {
      const messageEditor = () =>
        wrapper.findComponent({ name: 'WootMessageEditor' });
      messageEditor().vm.$emit('typingActivity');
      await flushPromises();
      wrapper.vm.setReplyMode(REPLY_EDITOR_MODES.NOTE);
      await nextTick();
      messageEditor().vm.$emit('typingActivity');
      await flushPromises();
      expect(
        publish.mock.calls.map(([target, , state]) => [target, state])
      ).toEqual([
        ['1/1', 'typing'],
        ['1/1', 'pause'],
      ]);

      wrapper.vm.setReplyMode(REPLY_EDITOR_MODES.REPLY);
      wrapper.vm.toggleAudioRecorder();
      await nextTick();
      const recorder = wrapper.findComponent({ name: 'AudioRecorder' });
      recorder.vm.$emit('recordingStarted');
      await flushPromises();
      recorder.vm.$emit('recordingStopped');
      await flushPromises();
      recorder.vm.$emit('recordingStarted');
      await flushPromises();
      route.params.conversation_id = '2';
      await flushPromises();
      expect(
        publish.mock.calls.map(([target, , state]) => [target, state])
      ).toEqual([
        ['1/1', 'typing'],
        ['1/1', 'pause'],
        ['1/1', 'recording'],
        ['1/1', 'pause'],
        ['1/1', 'recording'],
        ['1/1', 'pause'],
      ]);
    } finally {
      wrapper.unmount();
      publish.mockRestore();
    }
  });

  describe.each([false, true])(
    'sending audio in an API inbox with direct uploads set to %s',
    directUploadsEnabled => {
      const mountApiReplyBox = () =>
        mountWith({
          inbox: { channel_type: 'Channel::Api' },
          globalConfig: { directUploadsEnabled },
        }).wrapper;

      const audioAttachment = (name, isVoiceMessage) => ({
        resource: { file: new File(['audio'], name, { type: 'audio/ogg' }) },
        blobSignedId: `signed-${name}`,
        isVoiceMessage,
      });

      const attachmentFile = attachment =>
        directUploadsEnabled
          ? attachment.blobSignedId
          : attachment.resource.file;

      it('sends a microphone recording as a voice message', () => {
        const wrapper = mountApiReplyBox();
        const recording = audioAttachment('recording.ogg', true);
        wrapper.vm.attachedFiles = [recording];

        const payload = wrapper.vm.getMessagePayload('');

        expect(payload).toMatchObject({
          files: [attachmentFile(recording)],
          isVoiceMessage: true,
        });
        wrapper.unmount();
      });

      it('sends an uploaded OGG as an ordinary audio attachment', () => {
        const wrapper = mountApiReplyBox();
        const upload = audioAttachment('uploaded.ogg', false);
        wrapper.vm.attachedFiles = [upload];

        const payload = wrapper.vm.getMessagePayload('Caption');

        expect(payload.files).toEqual([attachmentFile(upload)]);
        expect(payload.isVoiceMessage).toBeUndefined();
        expect(payload.voiceMessageAttachmentIndices).toBeUndefined();
        wrapper.unmount();
      });

      it('keeps mixed audio in one reply with only the recording marked', () => {
        const wrapper = mountApiReplyBox();
        const upload = audioAttachment('uploaded.ogg', false);
        const recording = audioAttachment('recording.ogg', true);
        wrapper.vm.attachedFiles = [upload, recording];
        wrapper.vm.inReplyTo = { id: 15 };
        wrapper.vm.message = 'Caption';
        const sendMessage = vi
          .spyOn(wrapper.vm, 'sendMessage')
          .mockImplementation(() => {});

        wrapper.vm.confirmOnSendReply();

        expect(sendMessage).toHaveBeenCalledTimes(1);
        const [payload] = sendMessage.mock.calls[0];
        expect(payload).toMatchObject({
          files: [attachmentFile(upload), attachmentFile(recording)],
          message: 'Caption',
          private: false,
          contentAttributes: { in_reply_to: 15 },
          voiceMessageAttachmentIndices: [1],
        });
        expect(payload.isVoiceMessage).toBeUndefined();
        wrapper.unmount();
      });
    }
  );

  describe('Instagram incident restriction', () => {
    it('opens in note mode and restores only the private-note draft', async () => {
      const { wrapper, store } = mountWith({
        inbox: { channel_type: 'Channel::Instagram' },
        isMetaMessageSendingDisabled: true,
        drafts: {
          'draft-1-REPLY': 'unsent public reply',
          'draft-1-NOTE': 'incident note',
        },
      });
      await nextTick();

      expect(topPanel(wrapper).mode).toBe(REPLY_EDITOR_MODES.NOTE);
      expect(topPanel(wrapper).isReplyRestricted).toBe(true);
      expect(bottomPanel(wrapper).isOnPrivateNote).toBe(true);
      expect(editor(wrapper).editorId).toBe('draft-1-NOTE');
      expect(wrapper.vm.message).toBe('incident note');
      expect(store.getters['draftMessages/getReplyEditorMode']).toBe(
        REPLY_EDITOR_MODES.NOTE
      );
      expect(store.getters['draftMessages/get']('draft-1-REPLY')).toBe(
        'unsent public reply'
      );
    });

    it('preserves draft ownership when switching to a restricted conversation', async () => {
      const drafts = {
        'draft-1-REPLY': 'conversation A reply',
        'draft-1-NOTE': 'conversation A note',
        'draft-2-REPLY': 'conversation B reply',
        'draft-2-NOTE': 'conversation B note',
      };
      const { wrapper, store } = mountWith({
        inbox: { channel_type: 'Channel::WebWidget' },
        inboxes: {
          1: { channel_type: 'Channel::WebWidget' },
          2: { channel_type: 'Channel::Instagram' },
        },
        drafts,
        isMetaMessageSendingDisabled: true,
      });
      await nextTick();

      store.commit('selectChat', { ...REPLIABLE, id: 2, inbox_id: 2 });
      await nextTick();

      expect(editor(wrapper)).toMatchObject({
        editorId: 'draft-2-NOTE',
        modelValue: 'conversation B note',
      });
      Object.entries(drafts).forEach(([key, message]) => {
        expect(store.getters['draftMessages/get'](key)).toBe(message);
      });
    });
  });

  describe.each(CHANNELS)('$name', ({ name, inbox }) => {
    it('locks the composer and hides template sends when the conversation has an AI assignee', () => {
      const { wrapper } = mountWith({
        inbox,
        chat: {
          status: 'pending',
          meta: { sender: { id: 2 }, assignee_type: 'AgentBot' },
        },
      });

      expect(topPanel(wrapper).isReplyRestricted).toBe(true);
      expect(bottomPanel(wrapper).enableWhatsAppTemplates).toBe(false);
      expect(bottomPanel(wrapper).enableContentTemplates).toBe(false);
      // The note composer stays usable — this is a restriction, not a lockout.
      expect(topPanel(wrapper).isEditorDisabled).toBe(false);
    });

    it('opens directly in note mode when the conversation has an AI assignee', () => {
      const { wrapper, store } = mountWith({
        inbox,
        chat: {
          can_reply: false,
          status: 'pending',
          meta: { sender: { id: 2 }, assignee_type: 'AgentBot' },
        },
      });

      expect(bottomPanel(wrapper).isOnPrivateNote).toBe(true);
      expect(store.getters['draftMessages/getReplyEditorMode']).toBe(
        REPLY_EDITOR_MODES.NOTE
      );
      expect(topPanel(wrapper).isEditorDisabled).toBe(false);
    });

    it('opens in reply mode for every other conversation', () => {
      const { wrapper, store } = mountWith({ inbox });

      expect(bottomPanel(wrapper).isOnPrivateNote).toBe(false);
      expect(store.getters['draftMessages/getReplyEditorMode']).toBe(
        REPLY_EDITOR_MODES.REPLY
      );
    });

    it.each(['open', 'resolved', 'snoozed'])(
      'keeps the composer available when a %s conversation has an AI assignee',
      status => {
        const { wrapper } = mountWith({
          inbox,
          chat: {
            status,
            meta: { sender: { id: 2 }, assignee_type: 'AgentBot' },
          },
        });

        expect(topPanel(wrapper).isReplyRestricted).toBe(false);
        expect(bottomPanel(wrapper).enableWhatsAppTemplates).toBe(true);
      }
    );

    it('leaves the composer open when a human owns a pending conversation', () => {
      const { wrapper } = mountWith({
        inbox,
        chat: {
          status: 'pending',
          meta: { sender: { id: 2 }, assignee_type: 'User' },
        },
      });

      expect(topPanel(wrapper).isReplyRestricted).toBe(false);
      expect(bottomPanel(wrapper).enableWhatsAppTemplates).toBe(true);
    });

    it('matches the existing messaging-window rule when no bot is involved', () => {
      const { wrapper } = mountWith({
        inbox,
        chat: { can_reply: false, status: 'resolved' },
      });

      const stillRepliable = exemptFromMessagingWindow(name);
      expect(topPanel(wrapper).isReplyRestricted).toBe(!stillRepliable);
      expect(bottomPanel(wrapper).enableWhatsAppTemplates).toBe(stillRepliable);
      // WhatsApp/API disable the editor and steer to templates; everywhere
      // else the composer falls back to a usable private note.
      expect(topPanel(wrapper).isEditorDisabled).toBe(stillRepliable);
    });
  });

  it('locks the composer when the conversation has a Captain assistant assignee', () => {
    const { wrapper } = mountWith({
      inbox: { channel_type: 'Channel::WebWidget' },
      chat: {
        status: 'pending',
        meta: {
          sender: { id: 2 },
          assignee_type: 'Captain::Assistant',
        },
      },
    });

    expect(topPanel(wrapper).isReplyRestricted).toBe(true);
    expect(bottomPanel(wrapper).isOnPrivateNote).toBe(true);
  });

  it('hides the template action when the inbox has no templates synced', () => {
    const { wrapper } = mountWith({
      inbox: { channel_type: 'Channel::Whatsapp' },
      chat: { can_reply: false, status: 'open' },
      templates: [],
    });

    expect(bottomPanel(wrapper).enableWhatsAppTemplates).toBe(false);
    expect(topPanel(wrapper).isReplyRestricted).toBe(false);
  });

  describe('drafts', () => {
    const DRAFTS = {
      'draft-1-REPLY': 'half typed reply',
      'draft-1-NOTE': 'a note',
    };

    it('loads the note draft while the conversation has an AI assignee', async () => {
      const { wrapper } = mountWith({
        inbox: { channel_type: 'Channel::WebWidget' },
        chat: {
          status: 'pending',
          meta: { sender: { id: 2 }, assignee_type: 'AgentBot' },
        },
        drafts: DRAFTS,
      });
      await nextTick();

      expect(editor(wrapper)).toMatchObject({
        editorId: 'draft-1-NOTE',
        modelValue: 'a note',
      });
    });

    it('leaves the saved reply draft intact and restores it on takeover', async () => {
      const { wrapper, store } = mountWith({
        inbox: { channel_type: 'Channel::WebWidget' },
        chat: {
          status: 'pending',
          meta: { sender: { id: 2 }, assignee_type: 'AgentBot' },
        },
        drafts: DRAFTS,
      });
      await nextTick();
      expect(store.getters['draftMessages/get']('draft-1-REPLY')).toBe(
        'half typed reply'
      );

      store.commit('selectChat', {
        ...REPLIABLE,
        status: 'open',
        meta: { sender: { id: 2 }, assignee_type: 'User' },
      });
      await nextTick();

      expect(editor(wrapper)).toMatchObject({
        editorId: 'draft-1-REPLY',
        modelValue: 'half typed reply',
      });
    });
  });

  it('offers content templates on Twilio WhatsApp when the conversation has no AI assignee', () => {
    const { wrapper } = mountWith({
      inbox: { channel_type: 'Channel::TwilioSms', medium: 'whatsapp' },
      chat: { can_reply: true, status: 'open' },
    });

    expect(bottomPanel(wrapper).enableContentTemplates).toBe(true);
  });

  describe('on selecting a conversation', () => {
    const selectChat = async chat => {
      const { wrapper, store } = mountWith({
        inbox: { channel_type: 'Channel::WebWidget' },
      });
      store.commit('selectChat', { ...REPLIABLE, id: 99, ...chat });
      await nextTick();
      return { wrapper, store };
    };

    it('switches to note mode when a pending conversation has an AI assignee', async () => {
      const { wrapper } = await selectChat({
        status: 'pending',
        meta: { sender: { id: 2 }, assignee_type: 'AgentBot' },
      });

      expect(bottomPanel(wrapper).isOnPrivateNote).toBe(true);
    });

    it('stays in reply mode when a human owns a pending conversation', async () => {
      const { wrapper } = await selectChat({
        status: 'pending',
        meta: { sender: { id: 2 }, assignee_type: 'User' },
      });

      expect(bottomPanel(wrapper).isOnPrivateNote).toBe(false);
    });

    it('closes an open template modal when a bot takes over the conversation', async () => {
      const { wrapper, store } = mountWith({
        inbox: { channel_type: 'Channel::Whatsapp' },
      });
      wrapper
        .findComponent({ name: 'ReplyBottomPanel' })
        .vm.$emit('selectWhatsappTemplate');
      await nextTick();
      expect(wrapper.findComponent(WhatsappTemplates).props('show')).toBe(true);

      store.commit('selectChat', {
        ...REPLIABLE,
        status: 'pending',
        meta: { sender: { id: 2 }, assignee_type: 'AgentBot' },
      });
      await nextTick();

      expect(wrapper.findComponent(WhatsappTemplates).props('show')).toBe(
        false
      );
    });

    it('returns to reply mode once the agent takes over', async () => {
      const { wrapper, store } = await selectChat({
        status: 'pending',
        meta: { sender: { id: 2 }, assignee_type: 'AgentBot' },
      });
      expect(bottomPanel(wrapper).isOnPrivateNote).toBe(true);

      store.commit('selectChat', {
        ...REPLIABLE,
        id: 99,
        status: 'open',
        meta: { sender: { id: 2 }, assignee_type: 'User' },
      });
      await nextTick();

      expect(bottomPanel(wrapper).isOnPrivateNote).toBe(false);
      expect(topPanel(wrapper).isReplyRestricted).toBe(false);
      expect(store.getters['draftMessages/getReplyEditorMode']).toBe(
        REPLY_EDITOR_MODES.REPLY
      );
    });

    it('keeps the agent in note mode after they chose it themselves', async () => {
      const { wrapper } = await selectChat({});
      wrapper
        .findComponent({ name: 'ReplyTopPanel' })
        .vm.$emit('setReplyMode', REPLY_EDITOR_MODES.NOTE);
      await nextTick();

      expect(bottomPanel(wrapper).isOnPrivateNote).toBe(true);
    });

    it('mirrors the forced note mode into the draftMessages store', async () => {
      const { store } = await selectChat({
        status: 'pending',
        meta: { sender: { id: 2 }, assignee_type: 'AgentBot' },
      });

      expect(store.getters['draftMessages/getReplyEditorMode']).toBe(
        REPLY_EDITOR_MODES.NOTE
      );
    });
  });

  describe('send shortcut', () => {
    const pressEnter = init =>
      document.dispatchEvent(
        new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', ...init })
      );

    it('ignores Enter while an IME composition is active', async () => {
      const { wrapper } = mountWith({
        inbox: { channel_type: 'Channel::WebWidget' },
        uiSettings: { editor_message_key: 'enter' },
      });
      await flushPromises();
      wrapper.vm.isFocused = true;
      const onSendReply = vi
        .spyOn(wrapper.vm, 'onSendReply')
        .mockImplementation(() => {});

      pressEnter({ key: 'Process', isComposing: true });
      expect(onSendReply).not.toHaveBeenCalled();

      pressEnter({});
      expect(onSendReply).toHaveBeenCalledTimes(1);

      wrapper.unmount();
    });
  });

  describe('inserting content while a Copilot draft is open', () => {
    it('dismisses the draft and appends the text to the reply', async () => {
      const { wrapper } = mountWith({ chat: REPLIABLE });
      await flushPromises();
      wrapper.vm.message = 'Hello';
      wrapper.vm.copilot.showEditor.value = true;

      emitter.emit(BUS_EVENTS.INSERT_INTO_RICH_EDITOR, 'Thanks for writing');
      await nextTick();

      expect(wrapper.vm.copilot.isActive.value).toBe(false);
      expect(wrapper.vm.message).toBe('Hello\nThanks for writing');
      wrapper.unmount();
    });

    it('keeps the signature after the inserted text', async () => {
      const signature = 'Regards, Agent';
      const { wrapper } = mountWith({
        chat: REPLIABLE,
        inbox: { channel_type: 'Channel::WebWidget' },
        uiSettings: { channel_webwidget_signature_enabled: true },
        signature,
      });
      await flushPromises();
      wrapper.vm.message = appendSignature(
        'Hello',
        signature,
        'Channel::WebWidget'
      );
      wrapper.vm.copilot.showEditor.value = true;

      emitter.emit(BUS_EVENTS.INSERT_INTO_RICH_EDITOR, 'Thanks for writing');
      await nextTick();

      expect(wrapper.vm.message).toBe(
        appendSignature(
          'Hello\nThanks for writing',
          signature,
          'Channel::WebWidget'
        )
      );
      wrapper.unmount();
    });

    it('strips formatting the channel cannot carry', async () => {
      const { wrapper } = mountWith({
        chat: REPLIABLE,
        inbox: { channel_type: 'Channel::Api' },
      });
      await flushPromises();
      wrapper.vm.copilot.showEditor.value = true;

      emitter.emit(
        BUS_EVENTS.INSERT_INTO_RICH_EDITOR,
        'See [the docs](https://example.com) for `details`'
      );
      await nextTick();

      expect(wrapper.vm.message).toBe(
        'See the docs: https://example.com for details'
      );
      wrapper.unmount();
    });

    it('leaves the reply alone when the editor is showing', async () => {
      const { wrapper } = mountWith({ chat: REPLIABLE });
      await flushPromises();
      wrapper.vm.message = 'Hello';

      emitter.emit(BUS_EVENTS.INSERT_INTO_RICH_EDITOR, 'Thanks for writing');
      await nextTick();

      expect(wrapper.vm.message).toBe('Hello');
      wrapper.unmount();
    });
  });
});
