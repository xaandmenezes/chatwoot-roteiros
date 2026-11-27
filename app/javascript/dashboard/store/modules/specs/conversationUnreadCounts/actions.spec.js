import axios from 'axios';
import { actions } from '../../conversationUnreadCounts';
import types from '../../../mutation-types';

const commit = vi.fn();
global.axios = axios;
vi.mock('axios');

describe('#actions', () => {
  beforeEach(() => {
    commit.mockClear();
    axios.get.mockReset();
  });

  describe('#get', () => {
    it('commits unread counts when API is successful', async () => {
      const payload = {
        all_count: 2,
        inboxes: { 1: '2' },
        labels: { 3: 4 },
        teams: { 5: 6 },
        mentions_count: 7,
        participating_count: 8,
        unattended_count: 9,
        folders: { 10: 11 },
      };
      axios.get.mockResolvedValue({ data: { payload } });

      await actions.get({ commit });

      expect(axios.get).toHaveBeenCalledWith(
        '/api/v1/conversations/unread_counts',
        { params: { whatsapp_scope: 'inbox' } }
      );
      expect(commit.mock.calls).toEqual([
        [types.SET_CONVERSATION_UNREAD_COUNTS, payload],
      ]);
    });

    it('keeps group badges cleared when an earlier response arrives', async () => {
      let finishRequest;
      axios.get.mockImplementation(
        () =>
          new Promise(resolve => {
            finishRequest = resolve;
          })
      );
      const pending = actions.get({ commit });
      actions.clear({ commit });
      finishRequest({ data: { payload: { whatsapp_groups_count: 4 } } });
      await pending;

      expect(commit.mock.calls).toEqual([
        [types.SET_CONVERSATION_UNREAD_COUNTS, {}],
      ]);
    });

    it('does not commit when API fails', async () => {
      axios.get.mockRejectedValue({ message: 'Incorrect header' });

      await actions.get({ commit });

      expect(commit).not.toHaveBeenCalled();
    });
  });

  describe('#clear', () => {
    it('clears unread counts', () => {
      actions.clear({ commit });

      expect(commit).toHaveBeenCalledWith(
        types.SET_CONVERSATION_UNREAD_COUNTS,
        {}
      );
    });
  });
});
