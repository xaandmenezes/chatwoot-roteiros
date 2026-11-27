/* global axios */
import ApiClient from './ApiClient';

const RYZE_PRESENCE_TIMEOUT = 3000;

class ConversationApi extends ApiClient {
  constructor() {
    super('conversations', { accountScoped: true });
  }

  getLabels(conversationID) {
    return axios.get(`${this.url}/${conversationID}/labels`);
  }

  getCampaignHistory(conversationId, { before, signal } = {}) {
    return axios.get(`${this.url}/${conversationId}/campaign_history`, {
      params: { before },
      signal,
    });
  }

  updateLabels(conversationID, labels) {
    return axios.post(`${this.url}/${conversationID}/labels`, { labels });
  }

  getSuggestions(conversationID, type) {
    return axios.get(`${this.url}/${conversationID}/suggestions/${type}`);
  }

  publishRyzePresence(destination, composerId, state) {
    const [accountId, conversationId] = destination.split('/');
    return axios.post(
      `${this.apiVersion}/accounts/${accountId}/conversations/${conversationId}/ryze_presence`,
      { state, composer_id: composerId },
      { timeout: RYZE_PRESENCE_TIMEOUT }
    );
  }

  getUnreadCounts(params = {}) {
    return axios.get(`${this.url}/unread_counts`, { params });
  }
}

export default new ConversationApi();
