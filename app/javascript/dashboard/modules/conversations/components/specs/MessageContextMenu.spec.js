import { flushPromises, mount } from '@vue/test-utils';
import { defineComponent, h, ref } from 'vue';
import { useAlert } from 'dashboard/composables';
import { withFullI18n } from 'test-i18n';
import MessageContextMenu from '../MessageContextMenu.vue';

withFullI18n();

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));

const dispatch = vi.fn();
const post = vi.fn();

const DialogStub = defineComponent({
  props: {
    disableConfirmButton: Boolean,
    isLoading: Boolean,
  },
  emits: ['confirm', 'close'],
  setup(props, { emit, expose, slots }) {
    const opened = ref(false);
    expose({
      open() {
        opened.value = true;
      },
      close() {
        opened.value = false;
        emit('close');
      },
    });
    const submit = event => {
      event.preventDefault();
      emit('confirm');
    };
    return () =>
      opened.value
        ? h('form', { onSubmit: submit }, [
            slots.default?.(),
            h('button', {
              type: 'submit',
              disabled: props.disableConfirmButton || props.isLoading,
            }),
          ])
        : null;
  },
});

const mountMenu = enabledOptions =>
  mount(MessageContextMenu, {
    props: {
      message: {
        id: 1,
        content: 'Translated text',
        originalContent: 'Hello',
        conversation_id: 2,
      },
      isOpen: true,
      enabledOptions,
      contextMenuPosition: { x: 10, y: 20 },
      hideButton: true,
    },
    global: {
      mocks: {
        $store: {
          dispatch,
          getters: {
            'accounts/getAccount': () => ({}),
            getCurrentAccountId: 1,
            getUISettings: {},
          },
        },
      },
      stubs: {
        ContextMenu: { template: '<div><slot /></div>' },
        AddCannedModal: true,
        WootDeleteModal: true,
        ReportCaptainMessageDialog: true,
        NextButton: true,
        FluentIcon: true,
        Dialog: DialogStub,
      },
    },
  });

const menuItem = (wrapper, label) =>
  wrapper.findAll('.menu').find(item => item.text() === label);

describe('MessageContextMenu', () => {
  beforeEach(() => {
    vi.stubGlobal('axios', { post });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const openEditor = async () => {
    const wrapper = mountMenu({ edit: true });
    await menuItem(wrapper, 'Edit').trigger('click');
    await flushPromises();
    return wrapper;
  };

  it('opens the original text and updates the conversation only after confirmation', async () => {
    const saved = { id: 1, content: 'Edited', conversation_id: 2 };
    post.mockResolvedValue({ status: 200, data: saved });
    const wrapper = await openEditor();

    expect(wrapper.get('textarea').element.value).toBe('Hello');
    expect(wrapper.get('button[type="submit"]').element.disabled).toBe(true);
    await wrapper.get('textarea').setValue('Edited');
    await wrapper.get('form').trigger('submit');
    await flushPromises();

    expect(post).toHaveBeenCalledExactlyOnceWith(
      '/api/v1/conversations/2/messages/1/edit_content',
      { content: 'Edited' },
      expect.objectContaining({ timeout: 30_000 })
    );
    expect(dispatch).toHaveBeenCalledExactlyOnceWith('updateMessage', saved);
    expect(useAlert).toHaveBeenCalledWith('Message edited on WhatsApp.');
    expect(wrapper.find('form').exists()).toBe(false);
  });

  it('keeps the existing message in the store while WhatsApp confirmation is pending', async () => {
    post.mockResolvedValue({ status: 202, data: {} });
    const wrapper = await openEditor();
    await wrapper.get('textarea').setValue('Edited');
    await wrapper.get('form').trigger('submit');
    await flushPromises();

    expect(dispatch).not.toHaveBeenCalled();
    expect(useAlert).toHaveBeenCalledWith(
      'Waiting for WhatsApp to confirm the edit.'
    );
  });

  it('blocks blank content and repeated submissions while saving', async () => {
    let resolve;
    post.mockReturnValue(
      new Promise(done => {
        resolve = done;
      })
    );
    const wrapper = await openEditor();
    await wrapper.get('textarea').setValue('  ');
    await wrapper.get('form').trigger('submit');
    expect(post).not.toHaveBeenCalled();

    await wrapper.get('textarea').setValue('Edited');
    await wrapper.get('form').trigger('submit');
    await wrapper.get('form').trigger('submit');
    expect(post).toHaveBeenCalledTimes(1);
    expect(wrapper.get('textarea').element.disabled).toBe(true);

    resolve({ status: 202, data: {} });
    await flushPromises();
    expect(wrapper.find('form').exists()).toBe(false);
  });

  it.each([
    ['edit_expired', 'The WhatsApp editing window has closed.'],
    ['edit_failed', 'WhatsApp could not edit the message.'],
  ])(
    'shows the provider error %s and preserves the draft',
    async (errorCode, text) => {
      post.mockRejectedValue({ response: { data: { error_code: errorCode } } });
      const wrapper = await openEditor();
      await wrapper.get('textarea').setValue('Edited');
      await wrapper.get('form').trigger('submit');
      await flushPromises();

      expect(dispatch).not.toHaveBeenCalled();
      expect(wrapper.get('textarea').element.value).toBe('Edited');
      expect(wrapper.get('[role="alert"]').text()).toBe(text);
    }
  );

  it('lets agents open the localized editor from the keyboard', async () => {
    const wrapper = mountMenu({ edit: true });
    const { $i18n } = wrapper.vm;
    const previousLocale = $i18n.locale;
    try {
      $i18n.locale = 'pt_BR';
      await flushPromises();
      await menuItem(wrapper, 'Editar').trigger('keydown', { key: 'Enter' });
      await flushPromises();

      expect(wrapper.get('label').text()).toBe('Mensagem');
      expect(wrapper.get('textarea').element.value).toBe('Hello');
    } finally {
      $i18n.locale = previousLocale;
      wrapper.unmount();
    }
  });

  it('offers forward email first and emits it on click', async () => {
    const wrapper = mountMenu({ forwardEmail: true, copy: true });
    const labels = wrapper.findAll('.menu').map(item => item.text());

    expect(labels.slice(0, 2)).toEqual(['Forward email', 'Copy']);

    await menuItem(wrapper, 'Forward email').trigger('click');

    expect(wrapper.emitted('forwardEmail')).toHaveLength(1);
    expect(wrapper.emitted('close')).toHaveLength(1);
  });

  it('hides forward email when it is not enabled', () => {
    const wrapper = mountMenu({ copy: true });

    expect(menuItem(wrapper, 'Forward email')).toBeUndefined();
    expect(menuItem(wrapper, 'Copy')).toBeDefined();
  });
});
