import { effectScope, ref } from 'vue';
import { flushPromises } from '@vue/test-utils';
import ConversationApi from 'dashboard/api/conversations';
import { useRyzePresence } from '../useRyzePresence';

describe('Ryze composer presence', () => {
  let scope;
  let destination;
  let presence;
  let publish;

  beforeEach(() => {
    vi.useFakeTimers();
    destination = ref('1/42');
    publish = vi
      .spyOn(ConversationApi, 'publishRyzePresence')
      .mockResolvedValue({});
    scope = effectScope();
    presence = scope.run(() => useRyzePresence(destination));
  });

  afterEach(async () => {
    scope.stop();
    await flushPromises();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  const states = spy =>
    spy.mock.calls.map(([target, , state]) => [target, state]);

  it('sends one typing pulse for a burst and pauses after two seconds of inactivity', async () => {
    presence.typing();
    presence.typing();
    await flushPromises();
    expect(states(publish)).toEqual([['1/42', 'typing']]);

    await vi.advanceTimersByTimeAsync(1000);
    presence.typing();
    await vi.advanceTimersByTimeAsync(2000);
    expect(states(publish)).toEqual([
      ['1/42', 'typing'],
      ['1/42', 'pause'],
    ]);
  });

  it('renews recording and addressing survives a conversation or account change', async () => {
    presence.recording();
    await vi.advanceTimersByTimeAsync(4000);
    destination.value = '2/42';
    presence.typing();
    await flushPromises();

    expect(states(publish)).toEqual([
      ['1/42', 'recording'],
      ['1/42', 'recording'],
      ['1/42', 'pause'],
      ['2/42', 'typing'],
    ]);
  });

  it('stops for private mode and resumes only with a new public input', async () => {
    presence.typing();
    await flushPromises();
    destination.value = null;
    presence.typing();
    presence.recording();
    await vi.advanceTimersByTimeAsync(4000);
    destination.value = '1/42';
    expect(states(publish)).toEqual([
      ['1/42', 'typing'],
      ['1/42', 'pause'],
    ]);

    presence.typing();
    await flushPromises();
    scope.stop();
    await flushPromises();
    expect(states(publish)).toEqual([
      ['1/42', 'typing'],
      ['1/42', 'pause'],
      ['1/42', 'typing'],
      ['1/42', 'pause'],
    ]);
  });
});
