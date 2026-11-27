import { effectScope, nextTick, ref } from 'vue';
import { flushPromises } from '@vue/test-utils';
import { useAudioTranscriptions } from '../useAudioTranscriptions';

const makeAudioMessage = (...attachments) => ({
  attachments: attachments.map(id => ({ id, file_type: 'audio' })),
});

describe('useAudioTranscriptions', () => {
  let axios;

  beforeEach(() => {
    axios = { get: vi.fn() };
    vi.stubGlobal('axios', axios);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it('fetches audio attachments in one conversation-level request and keeps pending state', async () => {
    axios.get.mockResolvedValue({
      data: {
        transcriptions: [
          { attachment_id: 11, status: 'pending', text: null },
          { attachment_id: 12, status: 'completed', text: 'Hello there' },
        ],
      },
    });
    const scope = effectScope();
    const messages = ref([makeAudioMessage(11), makeAudioMessage(12)]);
    const conversationId = ref(42);
    const enabled = ref(true);
    let transcriptions;
    scope.run(() => {
      transcriptions = useAudioTranscriptions({
        messages,
        conversationId,
        enabled,
      });
    });

    await flushPromises();

    expect(axios.get).toHaveBeenCalledTimes(1);
    expect(axios.get.mock.calls[0][1].params).toEqual({
      attachment_ids: ['11', '12'],
    });
    expect(transcriptions.value).toEqual({
      11: { status: 'pending', text: null },
      12: { status: 'completed', text: 'Hello there' },
    });
    scope.stop();
  });

  it('splits attachment IDs into endpoint batches of at most 100', async () => {
    axios.get.mockResolvedValue({ data: { transcriptions: [] } });
    const scope = effectScope();
    const messages = ref(
      Array.from({ length: 101 }, (_, index) => makeAudioMessage(index + 1))
    );
    scope.run(() =>
      useAudioTranscriptions({
        messages,
        conversationId: ref(42),
        enabled: ref(true),
      })
    );

    await flushPromises();

    expect(axios.get).toHaveBeenCalledTimes(2);
    expect(axios.get.mock.calls[0][1].params.attachment_ids).toHaveLength(100);
    expect(axios.get.mock.calls[1][1].params.attachment_ids).toEqual(['101']);
    scope.stop();
  });

  it('does not show a failure for historical audio with no persisted transcription', async () => {
    vi.useFakeTimers();
    axios.get.mockResolvedValue({ data: { transcriptions: [] } });
    const scope = effectScope();
    const messages = ref([makeAudioMessage(11)]);
    let transcriptions;
    scope.run(() => {
      transcriptions = useAudioTranscriptions({
        messages,
        conversationId: ref(42),
        enabled: ref(true),
      });
    });
    await flushPromises();
    await vi.advanceTimersByTimeAsync(750);

    expect(transcriptions.value[11]).toEqual({ status: 'none', text: null });
    expect(axios.get).toHaveBeenCalledTimes(2);
    scope.stop();
  });

  it('keeps a live transcript that arrives while the aggregate request is in flight', async () => {
    let resolveRequest;
    axios.get.mockReturnValue(
      new Promise(resolve => {
        resolveRequest = resolve;
      })
    );
    const scope = effectScope();
    const messages = ref([makeAudioMessage(11)]);
    let transcriptions;
    scope.run(() => {
      transcriptions = useAudioTranscriptions({
        messages,
        conversationId: ref(42),
        enabled: ref(true),
      });
    });

    messages.value = [
      {
        attachments: [
          { id: 11, file_type: 'audio', transcribed_text: 'Live text' },
        ],
      },
    ];
    await nextTick();
    resolveRequest({
      data: {
        transcriptions: [{ attachment_id: 11, status: 'failed', text: null }],
      },
    });
    await flushPromises();

    expect(transcriptions.value[11]).toEqual({
      status: 'completed',
      text: 'Live text',
    });
    scope.stop();
  });

  it('batches new audio with existing pending audio in one finite refresh loop', async () => {
    vi.useFakeTimers();
    axios.get
      .mockResolvedValueOnce({
        data: {
          transcriptions: [
            { attachment_id: 11, status: 'pending', text: null },
          ],
        },
      })
      .mockResolvedValueOnce({
        data: {
          transcriptions: [
            { attachment_id: 12, status: 'pending', text: null },
          ],
        },
      })
      .mockResolvedValueOnce({
        data: {
          transcriptions: [
            { attachment_id: 11, status: 'pending', text: null },
            { attachment_id: 12, status: 'pending', text: null },
          ],
        },
      });
    const scope = effectScope();
    const messages = ref([makeAudioMessage(11)]);
    scope.run(() =>
      useAudioTranscriptions({
        messages,
        conversationId: ref(42),
        enabled: ref(true),
      })
    );
    await flushPromises();

    messages.value = [makeAudioMessage(11), makeAudioMessage(12)];
    await nextTick();
    await flushPromises();
    await vi.advanceTimersByTimeAsync(10_000);

    expect(
      axios.get.mock.calls.map(([, config]) => config.params.attachment_ids)
    ).toEqual([['11'], ['12'], ['11', '12']]);
    scope.stop();
  });

  it('ignores an old conversation response after switching to another conversation', async () => {
    let resolveOldRequest;
    axios.get
      .mockReturnValueOnce(
        new Promise(resolve => {
          resolveOldRequest = resolve;
        })
      )
      .mockResolvedValueOnce({
        data: {
          transcriptions: [
            {
              attachment_id: 22,
              status: 'completed',
              text: 'New conversation',
            },
          ],
        },
      });
    const scope = effectScope();
    const messages = ref([makeAudioMessage(11)]);
    const conversationId = ref(42);
    let transcriptions;
    scope.run(() => {
      transcriptions = useAudioTranscriptions({
        messages,
        conversationId,
        enabled: ref(true),
      });
    });
    conversationId.value = 43;
    messages.value = [makeAudioMessage(22)];
    await flushPromises();
    resolveOldRequest({
      data: {
        transcriptions: [
          { attachment_id: 11, status: 'completed', text: 'Old conversation' },
        ],
      },
    });
    await flushPromises();

    expect(transcriptions.value).toEqual({
      22: { status: 'completed', text: 'New conversation' },
    });
    scope.stop();
  });

  it('refreshes pending status beyond 15 seconds and stops after success', async () => {
    vi.useFakeTimers();
    axios.get
      .mockResolvedValueOnce({
        data: {
          transcriptions: [
            { attachment_id: 11, status: 'pending', text: null },
          ],
        },
      })
      .mockResolvedValueOnce({
        data: {
          transcriptions: [
            { attachment_id: 11, status: 'pending', text: null },
          ],
        },
      })
      .mockResolvedValueOnce({
        data: {
          transcriptions: [
            { attachment_id: 11, status: 'completed', text: 'Finished' },
          ],
        },
      });
    const scope = effectScope();
    const messages = ref([makeAudioMessage(11)]);
    let transcriptions;
    scope.run(() => {
      transcriptions = useAudioTranscriptions({
        messages,
        conversationId: ref(42),
        enabled: ref(true),
      });
    });
    await flushPromises();
    await vi.advanceTimersByTimeAsync(20_000);

    expect(axios.get).toHaveBeenCalledTimes(3);
    expect(transcriptions.value[11]).toEqual({
      status: 'completed',
      text: 'Finished',
    });
    scope.stop();
  });

  it('stops the pending refresh timer when the timeline unmounts', async () => {
    vi.useFakeTimers();
    axios.get.mockResolvedValue({
      data: {
        transcriptions: [{ attachment_id: 11, status: 'pending', text: null }],
      },
    });
    const scope = effectScope();
    scope.run(() =>
      useAudioTranscriptions({
        messages: ref([makeAudioMessage(11)]),
        conversationId: ref(42),
        enabled: ref(true),
      })
    );
    await flushPromises();
    scope.stop();
    await vi.advanceTimersByTimeAsync(20_000);

    expect(axios.get).toHaveBeenCalledTimes(1);
  });

  it('keeps lookup errors distinct from a failed transcription', async () => {
    axios.get.mockRejectedValue(new Error('network unavailable'));
    const scope = effectScope();
    let transcriptions;
    scope.run(() => {
      transcriptions = useAudioTranscriptions({
        messages: ref([makeAudioMessage(11)]),
        conversationId: ref(42),
        enabled: ref(true),
      });
    });
    await flushPromises();

    expect(transcriptions.value[11]).toEqual({
      status: 'lookup_error',
      text: null,
    });
    scope.stop();
  });
});
