require 'rails_helper'

RSpec.describe Ryze::IncomingMessageChange do
  let(:inbox) { create(:channel_api).reload.inbox }
  let(:account) { inbox.account }
  let(:chat_id) { '5511111111111@s.whatsapp.net' }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, additional_attributes: { whatsapp_jid: chat_id }) }
  let(:source_id) { 'TEST-WA-ORIGINAL' }
  let(:edited_at) { Time.iso8601('2026-01-02T10:00:01Z') }
  let!(:message) do
    create(:message, conversation: conversation, account: account, source_id: source_id, content: 'original',
                     content_attributes: { translations: { en: 'old' }, source_language: 'pt' })
  end

  def change_message(content: nil, at: nil, ids: [chat_id])
    described_class.new(inbox: inbox, source_id: source_id, chat_ids: ids, content: content, edited_at: at).perform
  end

  it 'updates the original text, marks it edited, and invalidates the old translation' do
    expect { change_message(content: 'edited', at: edited_at) }.not_to change(Message, :count)
    expect(message.reload).to have_attributes(content: 'edited', processed_message_content: 'edited', translations: nil)
    expect(message.content_attributes).to include('edited' => true)
  end

  it 'applies edits and revocations while the conversation is at its new-message limit' do
    with_modified_env CONVERSATION_MESSAGE_PER_MINUTE_LIMIT: '1' do
      change_message(content: 'edited', at: edited_at)
      expect(message.reload.content).to eq('edited')
      change_message
      expect(message.reload.deleted).to be(true)
    end
  end

  it 'keeps the latest revision across duplicate and out-of-order deliveries' do
    change_message(content: 'latest', at: edited_at)
    expect do
      change_message(content: 'latest', at: edited_at)
      change_message(content: 'stale', at: edited_at - 1.second)
    end.not_to(change { message.reload.updated_at })
    expect(message.content).to eq('latest')
  end

  it 'removes the original content and attachments once and never resurrects a revoked message' do
    account.update!(locale: :pt_BR)
    message.attachments.create!(account: account, file_type: :image, external_url: 'https://example.org/photo.jpg')
    expect { change_message }.not_to change(Message, :count)
    expect(message.reload).to have_attributes(deleted: true, content: I18n.t('conversations.messages.deleted', locale: :pt_BR), translations: nil)
    expect(message.attachments).to be_empty
    expect do
      change_message(content: 'late edit', at: edited_at)
      change_message
    end.not_to(change { message.reload.updated_at })
    expect(message.content).to eq(I18n.t('conversations.messages.deleted', locale: :pt_BR))
  end

  it 'matches the conversation JID against the provider chat aliases' do
    conversation.update!(additional_attributes: { whatsapp_jid: '123@lid' })
    change_message(content: 'edited', at: edited_at, ids: [chat_id, '123@lid'])
    expect(message.reload.content).to eq('edited')
  end

  it 'never matches another chat or a note or an outgoing message with the same source ID' do
    expect { change_message(ids: ['other@g.us']) }.to raise_error(ActiveRecord::RecordNotFound)
    message.update!(private: true)
    expect { change_message }.to raise_error(ActiveRecord::RecordNotFound)
    message.update!(private: false, message_type: :outgoing)
    expect { change_message }.to raise_error(ActiveRecord::RecordNotFound)
    expect(message.reload.content).to eq('original')
  end

  it 'isolates identical provider IDs and chat JIDs in another inbox' do
    other_inbox = create(:channel_api).reload.inbox
    other_chat = create(:conversation, account: other_inbox.account, inbox: other_inbox, additional_attributes: { whatsapp_jid: chat_id })
    other_message = create(:message, account: other_inbox.account, conversation: other_chat, source_id: source_id, content: 'other account')

    change_message(content: 'edited', at: edited_at)

    expect(message.reload.content).to eq('edited')
    expect(other_message.reload.content).to eq('other account')
  end

  it 'fails closed for ambiguous historical messages' do
    create(:message, conversation: conversation, account: account, source_id: source_id)
    expect { change_message }.to raise_error(ActiveRecord::SoleRecordExceeded)
    expect(message.reload.content).to eq('original')
  end
end
