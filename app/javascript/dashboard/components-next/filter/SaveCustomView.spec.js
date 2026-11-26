import { shallowMount, flushPromises } from '@vue/test-utils';
import SaveCustomView from './SaveCustomView.vue';
import Checkbox from 'next/checkbox/Checkbox.vue';

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));

const mountForm = (props, dispatch = vi.fn()) =>
  shallowMount(SaveCustomView, {
    props,
    global: {
      mocks: { $t: key => key, $store: { dispatch } },
      stubs: { Checkbox: false },
    },
  });

describe('SaveCustomView', () => {
  it('defaults to a personal folder and sends team visibility only when chosen', async () => {
    const dispatch = vi.fn();
    const form = mountForm({ canShare: true }, dispatch);
    const toggle = form.getComponent(Checkbox).get('input');
    expect(toggle.element.checked).toBe(false);

    await form.setData({ name: 'Open' });
    await toggle.setValue(true);
    await form.get('form').trigger('submit');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith(
      'customViews/create',
      expect.objectContaining({
        name: 'Open',
        filter_type: 0,
        visibility: 'team',
      })
    );
  });

  it.each([{ canShare: false }, { canShare: true, filterType: 1 }])(
    'hides team sharing for %o',
    props => {
      expect(mountForm(props).findComponent(Checkbox).exists()).toBe(false);
    }
  );

  it('keeps the form open and stays on the current route when saving fails', async () => {
    const openLastSavedItem = vi.fn();
    const form = mountForm(
      { openLastSavedItem },
      vi.fn().mockRejectedValue(new Error('Denied'))
    );
    await form.setData({ name: 'Open' });
    await form.get('form').trigger('submit');
    await flushPromises();
    expect(form.emitted('close')).toBeUndefined();
    expect(openLastSavedItem).not.toHaveBeenCalled();
  });
});
