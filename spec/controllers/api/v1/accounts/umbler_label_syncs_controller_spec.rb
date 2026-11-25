require 'rails_helper'

RSpec.describe 'Umbler contact label sync API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:url) { "/api/v1/accounts/#{account.id}/umbler_label_sync" }

  before { allow(UmblerLabels::Sync).to receive(:configured?).with(account).and_return(true) }

  it 'returns the disabled state without creating or starting a run' do
    allow(UmblerLabels::Sync).to receive(:configured?).with(account).and_return(false)
    get url, headers: admin.create_new_auth_token
    expect(response.parsed_body).to include('enabled' => false, 'status' => 'idle')

    expect { post url, headers: admin.create_new_auth_token }.not_to change(UmblerLabelSync, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'rejects ordinary agents and users outside the account' do
    [create(:user, account: account), create(:user)].each do |user|
      expect { post url, headers: user.create_new_auth_token }.not_to change(UmblerLabelSync, :count)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'returns the active run on repeated clicks and queues only once' do
    headers = admin.create_new_auth_token
    expect { 2.times { post url, headers: headers } }.to have_enqueued_job(UmblerLabels::BatchJob).exactly(:once)
    expect(response.parsed_body).to include('enabled' => true, 'status' => 'queued')
    get url, headers: headers
    expect(response.parsed_body.dig('counts', 'processed')).to eq(0)
  end

  it 'allows a fresh click after the queue could not accept the first job' do
    allow(UmblerLabels::BatchJob).to receive(:perform_later).and_return(false, true)
    headers = admin.create_new_auth_token
    post url, headers: headers
    expect(response.parsed_body['status']).to eq('failed')
    post url, headers: headers
    expect(response.parsed_body['status']).to eq('queued')
  end

  it 'allows the administrator to restart a stalled run' do
    old = UmblerLabelSync.create!(account: account, status: 'running', updated_at: 1.hour.ago)
    get url, headers: admin.create_new_auth_token
    expect(response.parsed_body['status']).to eq('failed')
    expect { post url, headers: admin.create_new_auth_token }.to change(UmblerLabelSync, :count).by(1)
    expect(old.reload.status).to eq('failed')
  end
end
