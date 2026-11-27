require 'rails_helper'

RSpec.describe Ryze::HistoryBinding do
  let(:inbox) { create(:channel_api).inbox }
  let(:conversation) { create(:conversation, account: inbox.account, inbox: inbox) }
  let(:jid) { '5511999999999@s.whatsapp.net' }

  around do |example|
    with_modified_env(RYZE_DIRECT_INBOX_ENABLED: 'true', RYZE_INSTANCE_NAME: 'test', RYZE_INBOX_ID: inbox.id.to_s,
                      RYZE_HISTORY_BINDING_SECRET: 'test-only') { example.run }
  end

  it 'binds the JID to the installation, row, display identity and contact mapping' do
    described_class.bind!(conversation.reload, jid)
    expect(described_class.verified?(conversation.reload)).to be(true)
    %i[id display_id inbox_id account_id contact_id contact_inbox_id].each do |field|
      changed = Conversation.find(conversation.id)
      changed[field] = conversation[field].to_i + 1
      expect(described_class.verified?(changed)).to be(false), field.to_s
    end
    with_modified_env(RYZE_INSTANCE_NAME: 'another') { expect(described_class.verified?(conversation)).to be(false) }
    conversation.additional_attributes['whatsapp_jid'] = '5511000000000@lid'
    expect(described_class.verified?(conversation)).to be(false)
  end

  it 'refuses to overwrite a different JID or provision without a secret' do
    conversation.update!(additional_attributes: { 'whatsapp_jid' => '5511000000000@lid' })
    expect { described_class.bind!(conversation, jid) }.to raise_error(ArgumentError, /different JID/)
    with_modified_env(RYZE_HISTORY_BINDING_SECRET: nil) do
      expect { described_class.bind!(conversation, jid) }.to raise_error(ArgumentError, /Missing/)
    end
    expect(conversation.reload.additional_attributes).not_to have_key(described_class::KEY)
  end
end
