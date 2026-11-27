require 'rails_helper'

RSpec.describe 'Incoming message replay in API inboxes', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:agent) { create(:user, account: account, role: :administrator) }

  def deliver(target = conversation, **attributes)
    post api_v1_account_conversation_messages_url(account_id: account.id, conversation_id: target.display_id),
         params: { message_type: 'incoming', content: 'Hello', source_id: 'provider-123' }.merge(attributes),
         headers: { api_access_token: agent.access_token.token }
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch('id')
  end

  it 'returns the original text message on redelivery without reopening the conversation' do
    original_id = deliver
    conversation.update!(status: :resolved)
    replay_id = deliver(echo_id: 'retry-echo')

    expect(replay_id).to eq(original_id)
    expect(response.parsed_body['echo_id']).to eq('retry-echo')
    expect(conversation.messages.incoming.pluck(:id)).to eq([original_id])
    expect(conversation.reload).to be_resolved
  end

  it 'preserves the current content when the original text is delivered again after an edit' do
    original_id = deliver
    Message.find(original_id).update!(content: 'Edited text')

    expect(deliver).to eq(original_id)
    expect(response.parsed_body.fetch('content')).to eq('Edited text')
    expect(conversation.messages.incoming.count).to eq(1)
  end

  it 'preserves deletion when the original text is delivered again after removal' do
    original_id = deliver
    delete api_v1_account_conversation_message_url(account_id: account.id, conversation_id: conversation.display_id, id: original_id),
           headers: { api_access_token: agent.access_token.token }
    expect(response).to have_http_status(:success)

    expect(deliver).to eq(original_id)
    expect(response.parsed_body.fetch('content_attributes')).to include('deleted' => true)
    expect(response.parsed_body.fetch('content')).to eq(I18n.t('conversations.messages.deleted'))
    expect(conversation.messages.incoming.count).to eq(1)
  end

  it 'scopes the provider ID to a conversation and preserves distinct events with identical content' do
    other_conversation = create(:conversation, account: account, inbox: inbox)
    ids = [deliver, deliver(other_conversation), deliver(source_id: 'provider-456'), deliver(source_id: nil), deliver(source_id: nil)]

    expect(ids.uniq.size).to eq(5)
  end

  it 'keeps a delivery with an attachment separate from a plain text delivery' do
    attachment = fixture_file_upload('spec/assets/avatar.png', 'image/png')
    attachment_id = deliver(attachments: [attachment])
    text_id = deliver

    expect(attachment_id).not_to eq(text_id)
    expect(deliver).to eq(text_id)
    expect(deliver(attachments: [fixture_file_upload('spec/assets/avatar.png', 'image/png')])).to eq(attachment_id)
    expect(Message.find(attachment_id).attachments.count).to eq(1)
  end

  it 'returns the earliest text message when historical duplicates already exist' do
    historical = Array.new(2) { create(:message, conversation: conversation, inbox: inbox, account: account, source_id: 'provider-123') }

    expect(deliver).to eq(historical.first.id)
    expect(conversation.messages.incoming.count).to eq(2)
  end

  it 'does not reuse a private note or outgoing message with the same source ID' do
    note_id = deliver(private: true)
    outgoing_id = deliver(message_type: 'outgoing')
    incoming_id = deliver

    expect([note_id, outgoing_id, incoming_id].uniq.size).to eq(3)
    expect(deliver).to eq(incoming_id)
  end
end
