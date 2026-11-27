import { computed, onScopeDispose, shallowRef, watch } from 'vue';
import ConversationApi from 'dashboard/api/conversations';
import { ATTACHMENT_TYPES } from 'dashboard/components-next/message/constants';

const MAX_ATTACHMENT_IDS_PER_REQUEST = 100;
const PENDING_POLL_INTERVAL_MS = 10_000;
const MISSING_ROW_RETRY_DELAY_MS = 750;
const MAX_PENDING_WINDOW_MS = 15 * 60 * 1000;

const getAudioAttachmentIds = messages => {
  const ids = new Set();
  messages.forEach(message => {
    (message.attachments || []).forEach(attachment => {
      if (
        attachment.file_type === ATTACHMENT_TYPES.AUDIO &&
        attachment.id !== null &&
        attachment.id !== undefined
      ) {
        ids.add(attachment.id);
      }
    });
  });
  return [...ids];
};

const getLiveTranscript = attachment =>
  attachment?.transcribed_text || attachment?.transcribedText;

export function useAudioTranscriptions({ conversationId, enabled, messages }) {
  const transcriptions = shallowRef({});
  const audioIdSignature = computed(() =>
    enabled.value
      ? getAudioAttachmentIds(messages.value).map(String).sort().join(',')
      : ''
  );
  let generation = 0;
  let timer = null;
  let stopped = false;
  let missingRetryIds = new Set();
  let missingRetryCounts = new Map();
  let pendingSince = new Map();

  const clearTimer = () => {
    if (timer) clearTimeout(timer);
    timer = null;
  };

  const setStatus = (attachmentId, value) => {
    transcriptions.value = {
      ...transcriptions.value,
      [String(attachmentId)]: value,
    };
  };

  async function fetchBatch(id, attachmentIds, currentGeneration) {
    const batches = [];
    for (
      let index = 0;
      index < attachmentIds.length;
      index += MAX_ATTACHMENT_IDS_PER_REQUEST
    ) {
      batches.push(
        attachmentIds.slice(index, index + MAX_ATTACHMENT_IDS_PER_REQUEST)
      );
    }

    await Promise.all(
      batches.map(async batch => {
        try {
          const { data } = await ConversationApi.getAudioTranscriptions(
            id,
            batch
          );
          if (stopped || currentGeneration !== generation) return;
          const returnedIds = new Set();
          const attachments = messages.value.flatMap(
            message => message.attachments || []
          );
          (data.transcriptions || []).forEach(result => {
            const attachmentId = String(result.attachment_id);
            returnedIds.add(attachmentId);
            const liveAttachment = attachments.find(
              attachment => String(attachment.id) === attachmentId
            );
            const liveTranscript = getLiveTranscript(liveAttachment);
            if (liveTranscript) {
              setStatus(attachmentId, {
                status: 'completed',
                text: liveTranscript,
              });
              pendingSince.delete(attachmentId);
              return;
            }
            setStatus(attachmentId, {
              status: result.status,
              text: result.text,
            });
            missingRetryCounts.delete(attachmentId);
            missingRetryIds.delete(attachmentId);
            if (result.status === 'pending') {
              if (!pendingSince.has(attachmentId)) {
                pendingSince.set(attachmentId, Date.now());
              }
            } else {
              pendingSince.delete(attachmentId);
            }
          });

          batch.forEach(attachmentId => {
            const normalizedId = String(attachmentId);
            if (returnedIds.has(normalizedId)) return;
            const retryCount = missingRetryCounts.get(normalizedId) || 0;
            if (retryCount === 0) {
              missingRetryCounts.set(normalizedId, 1);
              missingRetryIds.add(normalizedId);
            } else {
              // No persisted row means no transcript is available for this old/ineligible file.
              setStatus(normalizedId, { status: 'none', text: null });
              missingRetryCounts.delete(normalizedId);
            }
          });
        } catch {
          if (stopped || currentGeneration !== generation) return;
          batch.forEach(attachmentId => {
            const normalizedId = String(attachmentId);
            setStatus(normalizedId, { status: 'lookup_error', text: null });
            missingRetryIds.delete(normalizedId);
            pendingSince.delete(normalizedId);
          });
        }
      })
    );
  }

  const scheduleRefresh = (id, currentGeneration) => {
    if (timer || stopped || currentGeneration !== generation) return;
    const hasMissingRetry = missingRetryIds.size > 0;
    const hasPending = Object.values(transcriptions.value).some(
      value => value.status === 'pending'
    );
    if (!hasMissingRetry && !hasPending) return;

    timer = setTimeout(
      async () => {
        timer = null;
        if (stopped || currentGeneration !== generation) return;

        if (missingRetryIds.size) {
          const retryIds = [...missingRetryIds];
          missingRetryIds = new Set();
          await fetchBatch(id, retryIds, currentGeneration);
          scheduleRefresh(id, currentGeneration);
          return;
        }

        const now = Date.now();
        const pendingIds = Object.entries(transcriptions.value)
          .filter(([, value]) => value.status === 'pending')
          .map(([attachmentId]) => attachmentId);
        const expiredIds = pendingIds.filter(
          attachmentId =>
            now - (pendingSince.get(attachmentId) || now) >=
            MAX_PENDING_WINDOW_MS
        );
        expiredIds.forEach(attachmentId => {
          setStatus(attachmentId, { status: 'timed_out', text: null });
          pendingSince.delete(attachmentId);
        });

        const refreshIds = pendingIds.filter(
          idValue => !expiredIds.includes(idValue)
        );
        if (refreshIds.length) {
          await fetchBatch(id, refreshIds, currentGeneration);
        }
        scheduleRefresh(id, currentGeneration);
      },
      hasMissingRetry ? MISSING_ROW_RETRY_DELAY_MS : PENDING_POLL_INTERVAL_MS
    );
  };

  async function requestNewIds(id, ids, currentGeneration) {
    const newIds = ids
      .map(String)
      .filter(attachmentId => !transcriptions.value[attachmentId]);
    if (!newIds.length) return;

    const attachments = messages.value.flatMap(
      message => message.attachments || []
    );
    newIds.forEach(attachmentId => {
      const liveAttachment = attachments.find(
        attachment => String(attachment.id) === attachmentId
      );
      const liveTranscript = getLiveTranscript(liveAttachment);
      if (liveTranscript) {
        setStatus(attachmentId, { status: 'completed', text: liveTranscript });
      } else {
        // Optimistic display is replaced by the persisted API status or hidden when absent.
        setStatus(attachmentId, { status: 'pending', text: null });
      }
    });

    const idsToLookup = newIds.filter(
      attachmentId => transcriptions.value[attachmentId]?.status !== 'completed'
    );
    if (idsToLookup.length) {
      await fetchBatch(id, idsToLookup, currentGeneration);
      scheduleRefresh(id, currentGeneration);
    }
  }

  watch(
    [conversationId, enabled],
    ([id, isEnabled], _previous, onCleanup) => {
      generation += 1;
      clearTimer();
      missingRetryIds = new Set();
      missingRetryCounts = new Map();
      pendingSince = new Map();
      transcriptions.value = {};
      onCleanup(clearTimer);
      if (!id || !isEnabled) return;
      const ids = getAudioAttachmentIds(messages.value);
      if (ids.length) requestNewIds(id, ids, generation);
    },
    { immediate: true }
  );

  watch(audioIdSignature, signature => {
    const id = conversationId.value;
    if (!id || !enabled.value || !signature) return;
    requestNewIds(id, getAudioAttachmentIds(messages.value), generation);
  });

  onScopeDispose(() => {
    stopped = true;
    clearTimer();
  });

  return computed(() => transcriptions.value);
}
