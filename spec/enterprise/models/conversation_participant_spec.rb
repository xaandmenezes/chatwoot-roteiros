require 'rails_helper'

RSpec.describe ConversationParticipant do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:jid) { '120363000000000001@g.us' }
  let(:contact) { create(:contact, account: account, identifier: jid) }
  let(:binding) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: jid) }
  let(:group) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: binding) }

  around do |example|
    with_modified_env(RYZE_GROUPS_INBOX_ENABLED: 'true', RYZE_INBOX_ID: inbox.id.to_s) { example.run }
  end

  it 'notifies only the affected reader after adding and removing group participation' do
    role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
    account.account_users.find_by!(user: agent).update!(custom_role: role)
    create(:inbox_member, user: agent, inbox: inbox)
    event = [[agent.pubsub_token], 'conversation.whatsapp_group_access_changed', { account_id: account.id, conversation_id: group.display_id }]
    participant = nil

    expect do
      participant = create(:conversation_participant, account: account, user: agent, conversation: group)
    end.to have_enqueued_job(ActionCableBroadcastJob).with(*event)
    expect { participant.destroy! }.to have_enqueued_job(ActionCableBroadcastJob).with(*event)
  end
end
