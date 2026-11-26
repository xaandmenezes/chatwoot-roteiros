require 'rails_helper'

RSpec.describe UmblerLabels::BatchJob do
  let(:account) { create(:account) }
  let(:sync) { instance_double(UmblerLabels::Sync) }
  let(:first_contact) { create(:contact, account: account) }
  let(:second_contact) { create(:contact, account: account) }
  let(:run) { UmblerLabelSync.create!(account: account, last_contact_id: second_contact.id) }

  before do
    first_contact
    allow(UmblerLabels::Sync).to receive(:configured?).with(account).and_return(true)
    allow(UmblerLabels::Sync).to receive(:new).with(account).and_return(sync)
  end

  it 'processes just the original account and snapshot, resuming at the cursor across batches' do
    run
    create(:contact, account: account)
    create(:contact)
    stub_const('UmblerLabels::BatchJob::BATCH_SIZE', 1)
    allow(sync).to receive(:call).with(first_contact).and_return(:updated)
    allow(sync).to receive(:call).with(second_contact).and_return(:unchanged)

    expect { described_class.perform_now(run.id) }.to have_enqueued_job(described_class).with(run.id)
    expect(run.reload.counts).to include('processed' => 1, 'updated' => 1)
    described_class.perform_now(run.id)
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('completed')
    expect(run.counts).to include('processed' => 2, 'updated' => 1, 'unchanged' => 1)
    expect(sync).to have_received(:call).twice
  end

  it 'reports a partial failure and leaves completed work counted' do
    allow(sync).to receive(:call).with(first_contact).and_return(:no_labels)
    allow(sync).to receive(:call).with(second_contact).and_raise(UmblerLabels::Client::Error, 'provider error')

    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('failed')
    expect(run.counts).to include('processed' => 1, 'no_labels' => 1)
  end

  it 'stops before looking up contacts if the integration is disabled after a click' do
    allow(UmblerLabels::Sync).to receive(:configured?).with(account).and_return(false)
    described_class.perform_now(run.id)
    expect(run.reload).to be_failed
    expect(UmblerLabels::Sync).not_to have_received(:new)
  end

  it 'skips a duplicate delivery while a batch is already processing' do
    run.update!(status: 'running')
    described_class.perform_now(run.id)
    expect(UmblerLabels::Sync).not_to have_received(:new)
  end
end
