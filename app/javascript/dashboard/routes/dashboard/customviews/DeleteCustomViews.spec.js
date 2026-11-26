import { shallowMount } from '@vue/test-utils';
import { useAlert } from 'dashboard/composables';
import DeleteCustomViews from './DeleteCustomViews.vue';

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));

it('keeps the folder open and reports an unsuccessful deletion', async () => {
  const openLastItemAfterDelete = vi.fn();
  const wrapper = shallowMount(DeleteCustomViews, {
    props: { customViewsId: 42, openLastItemAfterDelete },
    global: {
      mocks: {
        $t: key => key,
        $store: { dispatch: vi.fn().mockRejectedValue(new Error('Denied')) },
      },
      stubs: { 'woot-delete-modal': true },
    },
  });
  await wrapper.vm.deleteSavedCustomViews();
  expect(useAlert).toHaveBeenCalledWith(
    'FILTER.CUSTOM_VIEWS.DELETE.API_FOLDERS.ERROR_MESSAGE'
  );
  expect(openLastItemAfterDelete).not.toHaveBeenCalled();
});
