import { flushPromises, mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import UmblerLabelSync from '../UmblerLabelSync.vue';

const ACCOUNT_URL = '/api/v1/accounts/1/umbler_label_sync';
const POLL_INTERVAL = 3000;
const PREFIX = 'CONTACTS_LAYOUT.UMBLER_LABEL_SYNC';
const result = (status, counts = {}) => ({
  data: { enabled: true, status, counts },
});

describe('Umbler label sync', () => {
  let wrapper;
  let store;
  const http = { get: vi.fn(), post: vi.fn() };

  beforeEach(() => {
    vi.useFakeTimers();
    vi.stubGlobal('axios', http);
    http.get.mockReset();
    http.post.mockReset();
    store = createStore({
      state: { accountId: 1, role: 'administrator' },
      getters: {
        getCurrentAccountId: state => state.accountId,
        getCurrentRole: state => state.role,
      },
      mutations: {
        switchAccount(state, accountId) {
          state.accountId = accountId;
        },
      },
    });
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = undefined;
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  const render = async () => {
    wrapper = mount(UmblerLabelSync, { global: { plugins: [store] } });
    await flushPromises();
  };

  const button = () => wrapper.find('button');
  const status = () => wrapper.get('[role="status"]');

  it('does not show the action or query the server for an agent', async () => {
    store.state.role = 'agent';

    await render();

    expect(button().exists()).toBe(false);
    expect(http.get).not.toHaveBeenCalled();
  });

  it('hides the action for an account where the sync is disabled', async () => {
    http.get.mockResolvedValue({ data: { enabled: false } });

    await render();

    expect(http.get).toHaveBeenCalledWith(
      ACCOUNT_URL,
      expect.objectContaining({ signal: expect.any(AbortSignal) })
    );
    expect(button().exists()).toBe(false);
  });

  it('offers a status retry after a temporary error loading the feature', async () => {
    http.get
      .mockRejectedValueOnce(new Error('network'))
      .mockResolvedValueOnce(result('idle'));

    await render();
    expect(status().text()).toBe(`${PREFIX}.LOAD_ERROR`);
    expect(button().text()).toBe(`${PREFIX}.RETRY`);

    await button().trigger('click');
    await flushPromises();
    expect(button().text()).toBe(`${PREFIX}.ACTION`);
    expect(http.post).not.toHaveBeenCalled();
  });

  it('hides the action when the server rejects access', async () => {
    http.get.mockRejectedValueOnce({ response: { status: 403 } });

    await render();

    expect(button().exists()).toBe(false);
  });

  it('starts only one job and then displays the completed result', async () => {
    http.get
      .mockResolvedValueOnce(result('idle'))
      .mockResolvedValueOnce(result('completed', { processed: 4, updated: 2 }));
    let resolveStart;
    http.post.mockImplementation(
      () =>
        new Promise(resolve => {
          resolveStart = resolve;
        })
    );

    await render();
    button().trigger('click');
    await button().trigger('click');

    expect(http.post).toHaveBeenCalledTimes(1);
    expect(http.post.mock.calls[0][0]).toBe(ACCOUNT_URL);
    expect(button().element.disabled).toBe(true);

    resolveStart(result('queued'));
    await flushPromises();
    expect(button().element.disabled).toBe(true);

    await vi.advanceTimersByTimeAsync(POLL_INTERVAL);
    expect(button().element.disabled).toBe(false);
    expect(status().text()).toBe(`${PREFIX}.RESULT`);
    expect(wrapper.emitted('labelsChanged')).toHaveLength(1);
  });

  it('resumes polling an existing job and cancels in-flight requests on unmount', async () => {
    http.get
      .mockResolvedValueOnce(result('running', { processed: 2 }))
      .mockImplementation(() => new Promise(() => {}));

    await render();
    expect(button().element.disabled).toBe(true);
    expect(status().text()).toBe(`${PREFIX}.RUNNING`);

    await vi.advanceTimersByTimeAsync(POLL_INTERVAL);
    expect(http.get).toHaveBeenCalledTimes(2);
    const { signal } = http.get.mock.calls[1][1];
    wrapper.unmount();
    wrapper = undefined;
    expect(signal.aborted).toBe(true);
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL);
    expect(http.get).toHaveBeenCalledTimes(2);
  });

  it('ignores results for the previous account', async () => {
    let resolveFirst;
    http.get
      .mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolveFirst = resolve;
          })
      )
      .mockResolvedValueOnce({ data: { enabled: false } });

    await render();
    store.commit('switchAccount', 2);
    await flushPromises();
    resolveFirst(result('running'));
    await flushPromises();

    expect(http.get.mock.calls[1][0]).toBe(
      '/api/v1/accounts/2/umbler_label_sync'
    );
    expect(button().exists()).toBe(false);
  });

  it('tries polling again after a temporary error and shows a failed job', async () => {
    http.get
      .mockResolvedValueOnce(result('running'))
      .mockRejectedValueOnce(new Error('network'))
      .mockResolvedValueOnce(result('failed', { processed: 3, updated: 2 }));

    await render();
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL);
    expect(button().element.disabled).toBe(true);
    expect(status().text()).toContain(`${PREFIX}.STATUS_ERROR`);

    await vi.advanceTimersByTimeAsync(POLL_INTERVAL);
    expect(button().element.disabled).toBe(false);
    expect(status().text()).toContain(`${PREFIX}.FAILED`);
    expect(status().text()).toContain(`${PREFIX}.RESULT`);
  });
});
