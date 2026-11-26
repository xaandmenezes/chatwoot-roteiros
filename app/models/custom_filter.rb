# == Schema Information
#
# Table name: custom_filters
#
#  id          :bigint           not null, primary key
#  filter_type :integer          default("conversation"), not null
#  name        :string           not null
#  query       :jsonb            not null
#  visibility  :string           default("personal"), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  account_id  :bigint           not null
#  user_id     :bigint
#
# Indexes
#
#  index_custom_filters_on_account_id  (account_id)
#  index_custom_filters_on_user_id     (user_id)
#
class CustomFilter < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :account

  enum :filter_type, { conversation: 0, contact: 1, report: 2 }
  enum :visibility, { personal: 'personal', team: 'team' }, validate: true

  scope :visible_to, ->(user) { personal.where(user: user).or(team.where(user_id: nil)) }

  validates :user, presence: true, if: :personal?
  validates :user_id, absence: true, if: :team?
  validates :filter_type, inclusion: { in: ['conversation'] }, if: :team?
  validate :validate_visibility_change, on: :update
  validate :validate_number_of_filters, on: :create
  after_create_commit :invalidate_filtered_unread_count_create, if: :personal?
  after_update_commit :invalidate_filtered_unread_count_update, if: :personal?
  after_destroy_commit :invalidate_filtered_unread_count_destroy, if: :personal?

  private

  def validate_number_of_filters
    return if account.custom_filters.where(user_id: user_id).count < Limits::MAX_CUSTOM_FILTERS_PER_USER

    limit_error = team? ? 'team_limit' : 'number_of_records'
    errors.add :account_id, I18n.t("errors.custom_filters.#{limit_error}")
  end

  def validate_visibility_change
    errors.add(:visibility, I18n.t('errors.custom_filters.visibility_change')) if will_save_change_to_visibility?
  end

  def invalidate_filtered_unread_count_create
    filtered_count_invalidator.custom_filter_created!(self)
  end

  def invalidate_filtered_unread_count_update
    filtered_count_invalidator.custom_filter_updated!(self)
  end

  def invalidate_filtered_unread_count_destroy
    filtered_count_invalidator.custom_filter_destroyed!(self)
  end

  def filtered_count_invalidator
    ::Conversations::UnreadCounts::FilteredCountInvalidator.new(account)
  end
end
