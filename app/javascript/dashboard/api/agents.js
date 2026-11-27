/* global axios */

import ApiClient from './ApiClient';

class Agents extends ApiClient {
  constructor() {
    super('agents', { accountScoped: true });
  }

  getInboxAccess(agentId) {
    return axios.get(`${this.url}/${agentId}/inbox_access`);
  }

  updateInboxAccess(agentId, inboxId, accessLevel) {
    return axios.patch(`${this.url}/${agentId}/inbox_access`, {
      inbox_id: inboxId,
      access_level: accessLevel,
    });
  }

  bulkInvite({ emails }) {
    return axios.post(`${this.url}/bulk_create`, {
      emails,
    });
  }
}

export default new Agents();
