require 'rails_helper'

RSpec.describe Ryze::ReactionRecipients do
  it 'broadcasts only to pilot inbox members and administrators allowed to see the conversation' do
    account = create(:account)
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox)
    admin = create(:user, account: account, role: :administrator)
    outside_agent = create(:user, account: account, role: :agent)
    participant = create(:user, account: account, role: :agent)
    other_inbox_member = create(:user, account: account, role: :agent)
    role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
    [participant, other_inbox_member].each do |agent|
      create(:inbox_member, user: agent, inbox: inbox)
      account.account_users.find_by!(user: agent).update!(custom_role: role)
    end
    create(:conversation_participant, conversation: conversation, account: account, user: participant)

    tokens = described_class.new(conversation).tokens
    expect(tokens).to contain_exactly(admin.pubsub_token, participant.pubsub_token)
    expect(tokens).not_to include(outside_agent.pubsub_token, conversation.contact_inbox.pubsub_token)
  end
end
