require 'rails_helper'

describe MessageFinder do
  subject(:message_finder) { described_class.new(conversation, params) }

  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:contact) { create(:contact, email: nil) }
  let!(:conversation) do
    create(:conversation, account: account, inbox: inbox, assignee: user, contact: contact)
  end

  before do
    create(:message, account: account, inbox: inbox, conversation: conversation)
    create(:message, message_type: 'activity', account: account, inbox: inbox, conversation: conversation)
    create(:message, message_type: 'activity', account: account, inbox: inbox, conversation: conversation)
    # this outgoing message creates 2 additional messages because of the email hook execution service
    create(:message, message_type: 'outgoing', account: account, inbox: inbox, conversation: conversation)
  end

  describe '#perform' do
    context 'with filter_internal_messages false' do
      let(:params) { { filter_internal_messages: false } }

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 6
      end
    end

    context 'with filter_internal_messages true' do
      let(:params) { { filter_internal_messages: true } }

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 4
      end
    end

    context 'with before attribute' do
      let!(:outgoing) { create(:message, message_type: 'outgoing', account: account, inbox: inbox, conversation: conversation) }
      let(:params) { { before: outgoing.id } }

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 6
      end
    end

    context 'with a before attribute above the message id range' do
      let!(:max_id_message) do
        create(:message, id: described_class::MESSAGE_ID_MAX, account: account, inbox: inbox, conversation: conversation)
      end
      let(:params) { { before: 4_611_686_018_427_387_903 } }

      it 'includes the maximum valid message id without overflowing the database column' do
        expect(message_finder.perform).to include(max_id_message)
      end
    end

    context 'with after attribute' do
      let(:params) { { after: conversation.messages.first.id } }

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 5
        expect(result.first.id).to be conversation.messages.second.id
        expect(result.last.message_type).to eq 'outgoing'
      end
    end

    context 'with an after attribute above the message id range' do
      let(:params) { { after: 881_965_304_328 } }

      it 'returns no messages without overflowing the database column' do
        expect(message_finder.perform).to be_empty
      end
    end

    context 'with after and before attribute' do
      let(:params) do
        {
          after: conversation.messages.first.id,
          before: conversation.messages.last.id
        }
      end

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 5
        expect(result.last.id).to be conversation.messages[-2].id
      end
    end

    context 'with a before attribute when an older message has a higher id' do
      let!(:cursor_message) do
        create(:message, account: account, inbox: inbox, conversation: conversation, created_at: 1.day.ago)
      end
      let!(:historical_message) do
        create(:message, account: account, inbox: inbox, conversation: conversation, created_at: 3.days.ago)
      end
      let(:params) { { before: cursor_message.id } }

      it 'returns messages older than the cursor message even if their id is higher' do
        expect(historical_message.id).to be > cursor_message.id
        result = message_finder.perform
        expect(result).to include(historical_message)
        expect(result).not_to include(cursor_message)
      end
    end

    context 'with a before attribute when messages share the exact same created_at' do
      let(:fixed_time) { 2.days.ago.change(usec: 0) }
      let!(:first_same_time) do
        create(:message, account: account, inbox: inbox, conversation: conversation, created_at: fixed_time)
      end
      let!(:second_same_time) do
        create(:message, account: account, inbox: inbox, conversation: conversation, created_at: fixed_time)
      end
      let(:params) { { before: second_same_time.id } }

      it 'breaks ties deterministically using id' do
        result = message_finder.perform
        expect(result).to include(first_same_time)
        expect(result).not_to include(second_same_time)
      end
    end

    context 'with a before attribute that does not exist in conversation messages' do
      let(:params) { { before: 999_999 } }

      it 'falls back to id < before_id query' do
        result = message_finder.perform
        expect(result).not_to be_empty
        expect(result.map(&:id)).to all(be < 999_999)
      end
    end

    context 'with after and before attributes above the message id range' do
      let!(:max_id_message) do
        create(:message, id: described_class::MESSAGE_ID_MAX, account: account, inbox: inbox, conversation: conversation)
      end
      let(:params) do
        {
          after: 881_965_304_328,
          before: 4_611_686_018_427_387_903
        }
      end

      it 'returns no messages' do
        result = message_finder.perform

        expect(result).to be_empty
        expect(result).not_to include(max_id_message)
      end
    end
  end
end
