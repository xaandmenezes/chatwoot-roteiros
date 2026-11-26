import { flushPromises, shallowMount } from '@vue/test-utils';
import WaveSurfer from 'wavesurfer.js';
import RecordPlugin from 'wavesurfer.js/dist/plugins/record.js';
import AudioRecorder from './AudioRecorder.vue';

vi.mock('wavesurfer.js', () => ({ default: { create: vi.fn() } }));
vi.mock('wavesurfer.js/dist/plugins/record.js', () => ({
  default: { create: vi.fn() },
}));

describe('AudioRecorder presence events', () => {
  let recorder;
  let events;

  const mountRecorder = () =>
    shallowMount(AudioRecorder, {
      props: { audioRecordFormat: 'audio/webm' },
    });

  beforeEach(() => {
    events = {};
    recorder = {
      on: (event, handler) => {
        events[event] = handler;
      },
      startRecording: vi.fn().mockResolvedValue(),
      stopRecording: vi.fn(),
      stopMic: vi.fn(),
    };
    RecordPlugin.create.mockReturnValue(recorder);
    WaveSurfer.create.mockReturnValue({
      plugins: [recorder],
      on: vi.fn(),
      destroy: vi.fn(),
    });
  });

  it('waits for the recorder to start and reports the stop before conversion', async () => {
    recorder.startRecording.mockImplementation(() => new Promise(() => {}));
    const wrapper = mountRecorder();
    expect(wrapper.emitted('recordingStarted')).toBeUndefined();

    events['record-start']();
    expect(wrapper.emitted('recordingStarted')).toHaveLength(1);

    events['record-end'](new Blob([], { type: 'audio/webm' }));
    expect(wrapper.emitted('recordingStopped')).toHaveLength(1);
    expect(wrapper.emitted('finishRecord')).toBeUndefined();
    wrapper.unmount();
    await flushPromises();
  });

  it('releases the microphone if permission arrives after the composer closes', async () => {
    let allowMicrophone;
    recorder.startRecording.mockImplementation(
      () =>
        new Promise(resolve => {
          allowMicrophone = resolve;
        })
    );
    const wrapper = mountRecorder();
    wrapper.unmount();
    events['record-start']();
    allowMicrophone();
    await flushPromises();

    expect(wrapper.emitted('recordingStarted')).toBeUndefined();
    expect(recorder.stopRecording).toHaveBeenCalledOnce();
    expect(recorder.stopMic).toHaveBeenCalledOnce();
  });

  it('reports a denied microphone without publishing recording presence', async () => {
    const error = new Error('Permission denied');
    recorder.startRecording.mockRejectedValue(error);
    const wrapper = mountRecorder();
    await flushPromises();

    expect(wrapper.emitted('recordingStarted')).toBeUndefined();
    expect(wrapper.emitted('recordError')).toEqual([[{ error }]]);
    wrapper.unmount();
  });
});
