import { onScopeDispose, watch } from 'vue';
import ConversationApi from 'dashboard/api/conversations';
import getUuid from 'widget/helpers/uuid';

const PULSE_INTERVAL = 4000;
const TYPING_IDLE_TIME = 2000;

export function useRyzePresence(destination) {
  let composerId;
  let activity;
  let heartbeat;
  let idleTimer;
  let request = Promise.resolve();

  const publish = (session, state) => {
    // Keep pause and the next public pulse in order, even when switching accounts.
    request = request
      .then(async () => {
        if (state === 'pause' ? !session.attempted : activity !== session)
          return;
        session.attempted = true;
        composerId ||= getUuid();
        await ConversationApi.publishRyzePresence(
          session.destination,
          composerId,
          state
        );
      })
      .catch(() => {
        // Transient presence must never interrupt composing or sending a reply.
      });
  };

  const stop = state => {
    if (!activity || (state && activity.state !== state)) return;

    const session = activity;
    activity = null;
    clearInterval(heartbeat);
    clearTimeout(idleTimer);
    publish(session, 'pause');
  };

  const start = state => {
    if (!destination.value || activity?.state === state) return;

    stop();
    const session = { destination: destination.value, state, attempted: false };
    activity = session;
    publish(session, state);
    heartbeat = setInterval(() => publish(session, state), PULSE_INTERVAL);
  };

  watch(destination, () => stop(), { flush: 'sync' });
  onScopeDispose(() => stop());

  return {
    typing() {
      if (!destination.value) return;
      start('typing');
      clearTimeout(idleTimer);
      idleTimer = setTimeout(() => stop('typing'), TYPING_IDLE_TIME);
    },
    recording: () => start('recording'),
    stop,
  };
}
