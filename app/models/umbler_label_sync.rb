class UmblerLabelSync < ApplicationRecord
  belongs_to :account

  OUTCOMES = %w[updated unchanged no_labels unmatched ambiguous].freeze
  EMPTY_COUNTS = (OUTCOMES + ['processed']).index_with(0).freeze
  STALL_TIMEOUT = 15.minutes

  enum :status, { queued: 0, running: 1, completed: 2, failed: 3 }

  after_create_commit :enqueue_batch, if: :queued?

  def self.latest(account)
    where(account: account).order(id: :desc).first
  end

  def self.start!(account)
    account.with_lock do
      previous = latest(account)
      previous&.lock!
      return previous if previous&.active?

      previous.update!(status: :failed) if previous&.stalled?
      create!(account: account, last_contact_id: account.contacts.maximum(:id) || 0)
    end
  end

  def stalled?
    (queued? || running?) && updated_at <= STALL_TIMEOUT.ago
  end

  def active?
    (queued? || running?) && !stalled?
  end

  def report
    { status: stalled? ? 'failed' : status, counts: EMPTY_COUNTS.merge(counts) }
  end

  def enqueue_batch
    job = UmblerLabels::BatchJob.perform_later(id)
    raise ActiveJob::EnqueueError unless job
  rescue StandardError => e
    fail_if!('queued')
    Rails.logger.error("Umbler label sync #{id} enqueue failed (#{e.class.name})")
  end

  def fail_if!(expected_status)
    with_lock { update!(status: :failed) if status == expected_status }
  end
end
