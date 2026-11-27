require 'rails_helper'

RSpec.describe RoomChannel do
  let!(:contact_inbox) { create(:contact_inbox) }
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }

  before do
    stub_connection
  end

  it 'subscribes to a stream when pubsub_token is provided' do
    subscribe(pubsub_token: contact_inbox.pubsub_token)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(contact_inbox.pubsub_token)
  end

  it 'subscribes to a stream when pubsub_token is provided for user' do
    subscribe(user_id: user.id, pubsub_token: user.pubsub_token, account_id: account.id)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(user.pubsub_token)
    expect(subscription).to have_stream_for("account_#{account.id}")
  end

  it 'wakes waiting pilot conversations when an eligible agent connects' do
    inbox = create(:inbox, account: account, enable_auto_assignment: true)
    create(:inbox_member, inbox: inbox, user: user)
    user.account_users.find_by!(account: account).online!
    expect(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox).with(inbox.id)

    with_modified_env(PSR_RESTRICTED_INBOX_ID: inbox.id.to_s, PSR_RANDOM_ASSIGNMENT_START_AT: 1.day.ago.iso8601) do
      subscribe(user_id: user.id, pubsub_token: user.pubsub_token, account_id: account.id)
    end
  end

  context 'when a customer subscribes to the restricted API inbox' do
    let(:pilot_inbox) { create(:channel_api, account: account).inbox }
    let(:contact) { create(:contact, account: account, identifier: 'local-contact') }
    let(:binding) { create(:contact_inbox, inbox: pilot_inbox, contact: contact) }

    around do |example|
      with_modified_env(PSR_RESTRICTED_INBOX_ID: pilot_inbox.id.to_s) { example.run }
    end

    it 'rejects a previously issued token on its own' do
      subscribe(pubsub_token: binding.pubsub_token)
      expect(subscription).to be_rejected
    end

    it 'accepts the verified customer session' do
      proof = OpenSSL::HMAC.hexdigest('sha256', pilot_inbox.channel.hmac_token, contact.identifier)
      subscribe(pubsub_token: binding.pubsub_token, identifier: contact.identifier, identifier_hash: proof)
      expect(subscription).to have_stream_for(binding.pubsub_token)
    end
  end

  it 'sends the agent their work preferences with presence' do
    user.account_users.find_by(account: account).update!(accepts_calls: false)

    expect { subscribe(user_id: user.id, pubsub_token: user.pubsub_token, account_id: account.id) }
      .to have_broadcasted_to(user.pubsub_token).with(
        hash_including(data: hash_including(work_preferences: { 'accepts_conversations' => true, 'accepts_calls' => false }))
      )
  end

  it 'does not send work preferences to a contact' do
    expect { subscribe(pubsub_token: contact_inbox.pubsub_token) }
      .to have_broadcasted_to(contact_inbox.pubsub_token).with(hash_including(data: hash_excluding(:work_preferences)))
  end
end
