require 'rails_helper'

RSpec.describe AutomationRules::MessageEditedJob do
  let(:account) { create(:account) }
  let(:message) { create(:message, account: account) }
  let(:rule) do
    create(:automation_rule, account: account, event_name: 'message_edited',
                             conditions: [{ attribute_key: 'content', filter_operator: 'equal_to', values: ['corrected'] }],
                             actions: [{ action_name: 'add_private_note', action_params: ['matched'] }])
  end
  let(:arguments) { [message, 'revision-1', 'Corrected', Time.current] }

  it 'keeps the claim if the worker fails after acting and a retry cannot repeat the action' do
    rule
    allow(AutomationRules::ActionService).to receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap do |service|
        allow(service).to receive(:perform).and_wrap_original do |perform|
          perform.call
          raise 'interrupted after actions'
        end
      end
    end

    expect { described_class.perform_now(*arguments) }.to raise_error('interrupted after actions')
    described_class.perform_now(*arguments)
    expect(rule.pending_executions.sole).to be_executing
    expect(message.conversation.messages.where(private: true).pluck(:content)).to eq(['matched'])
  end

  it 'does not replay an edit after the execution record is purged' do
    rule
    described_class.perform_now(*arguments)
    travel_to(AutomationRulePendingExecution::RETENTION_WINDOW.from_now + 1.day) do
      AutomationRulePendingExecution.purge_terminal!
      expect(rule.pending_executions).to be_empty
      described_class.perform_now(*arguments)
    end
    expect(message.conversation.messages.where(private: true).pluck(:content)).to eq(['matched'])
  end
end
