require 'rails_helper'

describe ConversationBuilder do
  let(:account) { create(:account) }
  let!(:sms_channel) { create(:channel_sms, account: account) }
  let!(:api_channel) { create(:channel_api, account: account) }
  let!(:sms_inbox) { create(:inbox, channel: sms_channel, account: account) }
  let!(:api_inbox) { create(:inbox, channel: api_channel, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_sms_inbox) { create(:contact_inbox, contact: contact, inbox: sms_inbox) }
  let(:contact_api_inbox) { create(:contact_inbox, contact: contact, inbox: api_inbox) }

  describe '#perform' do
    it 'creates sms conversation' do
      conversation = described_class.new(
        contact_inbox: contact_sms_inbox,
        params: {}
      ).perform

      expect(conversation.contact_inbox_id).to eq(contact_sms_inbox.id)
    end

    it 'creates api conversation' do
      conversation = described_class.new(
        contact_inbox: contact_api_inbox,
        params: {}
      ).perform

      expect(conversation.contact_inbox_id).to eq(contact_api_inbox.id)
    end

    it 'preserves caller metadata and leaves internal conversation state to the server' do
      params = ActionController::Parameters.new(
        additional_attributes: { browser: { name: 'Fixture' }, mail_subject: 'Fixture subject', auto_reply: true,
                                 captain_waiting_resolved_at: Time.current.iso8601 },
        custom_attributes: { reference: 'fixture' }
      )

      conversation = described_class.new(contact_inbox: contact_api_inbox, params: params).perform.reload

      expect(conversation.additional_attributes).to eq('browser' => { 'name' => 'Fixture' }, 'mail_subject' => 'Fixture subject')
      expect(conversation.custom_attributes).to eq('reference' => 'fixture')
    end

    it 'leaves Telegram routing fields to the channel' do
      channel = create(:channel_telegram, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: channel.inbox)
      params = ActionController::Parameters.new(additional_attributes: { chat_id: 'fixture', business_connection_id: 'fixture' })

      conversation = described_class.new(contact_inbox: contact_inbox, params: params).perform.reload

      expect(conversation.additional_attributes).to be_empty
    end

    it 'leaves TikTok routing and capabilities to the channel' do
      channel = create(:channel_tiktok, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: channel.inbox)
      params = ActionController::Parameters.new(additional_attributes: { conversation_id: 'fixture', tiktok_capabilities: { image_send: true } })

      conversation = described_class.new(contact_inbox: contact_inbox, params: params).perform.reload

      expect(conversation.additional_attributes).to be_empty
    end

    it 'leaves WhatsApp call permission tracking to the channel' do
      channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: channel.inbox)
      params = ActionController::Parameters.new(
        additional_attributes: { call_permission_requests: { 'fixture' => {} }, call_permission_requested_at: Time.current.iso8601,
                                 call_permission_request_message_id: 'fixture' }
      )

      conversation = described_class.new(contact_inbox: contact_inbox, params: params).perform.reload

      expect(conversation.additional_attributes).to be_empty
    end

    context 'when lock_to_single_conversation is true for sms inbox' do
      before do
        sms_inbox.update!(lock_to_single_conversation: true)
      end

      it 'creates sms conversation when existing conversation is not present' do
        conversation = described_class.new(
          contact_inbox: contact_sms_inbox,
          params: {}
        ).perform

        expect(conversation.contact_inbox_id).to eq(contact_sms_inbox.id)
      end

      it 'returns last from existing sms conversations when existing conversation is not present' do
        create(:conversation, contact_inbox: contact_sms_inbox)
        existing_conversation = create(:conversation, contact_inbox: contact_sms_inbox)
        conversation = described_class.new(
          contact_inbox: contact_sms_inbox,
          params: {}
        ).perform

        expect(conversation.id).to eq(existing_conversation.id)
      end
    end

    context 'when lock_to_single_conversation is true for api inbox' do
      before do
        api_inbox.update!(lock_to_single_conversation: true)
      end

      it 'creates conversation when existing api conversation is not present' do
        conversation = described_class.new(
          contact_inbox: contact_api_inbox,
          params: {}
        ).perform

        expect(conversation.contact_inbox_id).to eq(contact_api_inbox.id)
      end

      it 'returns last from existing api conversations when existing conversation is not present' do
        create(:conversation, contact_inbox: contact_api_inbox)
        existing_conversation = create(:conversation, contact_inbox: contact_api_inbox)
        conversation = described_class.new(
          contact_inbox: contact_api_inbox,
          params: {}
        ).perform

        expect(conversation.id).to eq(existing_conversation.id)
      end
    end
  end
end
