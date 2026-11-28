/* global axios */
import ApiClient from '../ApiClient';

class ViariAPI extends ApiClient {
  constructor() {
    super('conversations', { accountScoped: true });
  }

  async read(conversationId, action, params, signal) {
    const { data } = await axios.get(`${this.url}/${conversationId}/viari`, {
      params: { acao: action, ...params },
      signal,
    });
    return data.data;
  }

  async command(conversationId, action, params, key, signal) {
    const { data } = await axios.post(
      `${this.url}/${conversationId}/viari`,
      { acao: action, ...params },
      { headers: { 'Idempotency-Key': key }, signal }
    );
    return data.data;
  }
}

export default new ViariAPI();
