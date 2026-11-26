require 'rails_helper'

RSpec.describe CustomFilter do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:store) { Conversations::UnreadCounts::FilteredCountStore }

  before do
    account.enable_features!(:unread_count_for_filters)
  end

  it 'limits team folders per account independently of personal folders and allows edits at the limit' do
    stub_const('Limits::MAX_CUSTOM_FILTERS_PER_USER', 1)
    create(:custom_filter, user: user, account: account)
    folder = create(:custom_filter, visibility: :team, user: nil, account: account)
    expect(build(:custom_filter, visibility: :team, user: nil, account: account)).not_to be_valid
    expect(folder.update(name: 'Bookings')).to be(true)
  end

  describe 'filtered unread count invalidation' do
    it 'keeps team folders out of the personal unread count cache' do
      folder = create(:custom_filter, visibility: :team, user: nil, account: account)
      folder.update!(query: { payload: [] })
      expect(store.filter_version(account_id: account.id, filter_id: folder.id)).to eq(0)
      expect(store.folder_index_version(account_id: account.id, user_id: user.id)).to eq(0)
    end

    it 'invalidates the folder index and filter version when a conversation filter is created' do
      custom_filter = nil

      expect do
        custom_filter = create(:custom_filter, account: account, user: user, filter_type: :conversation)
      end.to change { store.folder_index_version(account_id: account.id, user_id: user.id) }.by(1)
      expect(store.filter_version(account_id: account.id, filter_id: custom_filter.id)).to eq(1)
    end

    it 'invalidates only the filter version when the query changes' do
      custom_filter = create(:custom_filter, account: account, user: user, filter_type: :conversation)
      folder_index_version = store.folder_index_version(account_id: account.id, user_id: user.id)

      expect do
        custom_filter.update!(query: { payload: [{ attribute_key: 'status', values: ['resolved'] }] })
      end.to(change { store.filter_version(account_id: account.id, filter_id: custom_filter.id) }.by(1))
      expect(store.folder_index_version(account_id: account.id, user_id: user.id)).to eq(folder_index_version)
    end

    it 'does not invalidate counts when only the name changes' do
      custom_filter = create(:custom_filter, account: account, user: user, filter_type: :conversation)

      expect do
        custom_filter.update!(name: 'Renamed filter')
      end.not_to(change { store.filter_version(account_id: account.id, filter_id: custom_filter.id) })
    end

    it 'invalidates the folder index and deletes the count when a conversation filter is destroyed' do
      custom_filter = create(:custom_filter, account: account, user: user, filter_type: :conversation)
      store.write_filter_count!(
        account_id: account.id,
        filter_id: custom_filter.id,
        user_id: user.id,
        count: 3,
        account_version: 0,
        filter_version: 0,
        owner_built_in_filter_version: 0
      )

      expect do
        custom_filter.destroy!
      end.to change { store.folder_index_version(account_id: account.id, user_id: user.id) }.by(1)
      expect(store.filter_count(account_id: account.id, filter_id: custom_filter.id)).to be_nil
    end
  end
end
