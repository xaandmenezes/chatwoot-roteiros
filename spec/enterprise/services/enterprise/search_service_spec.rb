require 'rails_helper'

RSpec.describe Enterprise::SearchService do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
  let(:other) { create(:conversation, account: account, inbox: inbox) }

  after { Current.reset }

  it 'searches transcriptions and email subjects within current assignments before pagination' do
    create(:inbox_member, inbox: inbox, user: agent)
    account.enable_features!('advanced_search')
    account.disable_features!('search_with_gin')
    allow(ChatwootApp).to receive(:advanced_search_allowed?).and_return(true)
    audio = create(:message, account: account, inbox: inbox, conversation: conversation)
    audio.attachments.create!(account: account, file_type: :audio, meta: { transcribed_text: 'Destino Pitinga' })
    subject_match = { email: { subject: 'Pitinga hoje' } }
    email = create(:message, account: account, inbox: inbox, conversation: conversation, content_attributes: subject_match)
    create(:message, account: account, inbox: inbox, conversation: other, content_attributes: subject_match)

    with_modified_env(PSR_RESTRICTED_INBOX_ID: inbox.id.to_s) do
      search = SearchService.new(current_user: agent, current_account: account, params: { q: 'Pitinga' }, search_type: 'Message')
      Current.account = account
      expect(search.perform.fetch(:messages)).to contain_exactly(email, audio)
    end
  end
end
