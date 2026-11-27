class Ryze::AudioTranscription < ApplicationRecord
  self.table_name = 'ryze_audio_transcriptions'

  ENTIRE_INBOX = 'all'.freeze
  MAX_ATTEMPTS = 3
  CLAIM_DURATION = 5.minutes
  RETRY_DELAY = 30.seconds

  belongs_to :attachment, inverse_of: :ryze_audio_transcription
  enum :status, { pending: 0, completed: 1, failed: 2 }
  attribute :next_attempt_at, default: -> { Time.current }
  after_create_commit :enqueue_processing, if: :pending?

  validates :text, presence: true, if: :completed?
  validates :text, length: { maximum: MAX_TEXT_COLUMN_LENGTH }, allow_nil: true

  scope :due, -> { pending.where(next_attempt_at: ..Time.current) }

  def self.record_attachment!(attachment)
    return unless enabled_for_attachment?(attachment)

    create_or_find_by!(attachment: attachment)
  end

  def self.enabled_for_attachment?(attachment)
    inbox_id = configured_inbox_id
    return false unless inbox_id && attachment.audio?

    message = attachment.message
    return false unless message&.inbox_id == inbox_id
    return false unless eligible_message?(message)

    conversation = message.conversation
    same_account?(attachment, message, conversation) && enabled_for_conversation?(conversation)
  end

  def self.enabled_for_conversation?(conversation)
    inbox_id = configured_inbox_id
    return false unless inbox_id && conversation.inbox_id == inbox_id
    return false unless conversation.inbox&.api? && conversation.inbox.account_id == conversation.account_id

    conversation_in_scope?(conversation)
  end

  def self.conversation_in_scope?(conversation)
    pilot_id = pilot_setting
    return true if pilot_id == ENTIRE_INBOX

    display_id = positive_id(pilot_id)
    display_id.present? && conversation.display_id == display_id
  end

  def self.next_due
    inbox_id = configured_inbox_id
    return unless inbox_id

    pilot_id = pilot_setting
    display_id = positive_id(pilot_id)
    return unless pilot_id == ENTIRE_INBOX || display_id

    records = due.joins(attachment: { message: { conversation: :inbox } })
                 .where(inboxes: { id: inbox_id, channel_type: 'Channel::Api' })
    records = records.where(conversations: { display_id: display_id }) if display_id
    records.order(:next_attempt_at, :id).first
  end

  def self.same_account?(attachment, message, conversation)
    ids = [attachment.account_id, message.account_id, conversation&.account_id]
    ids.all?(attachment.account_id)
  end

  def self.eligible_message?(message)
    return false if message.private? || message.historical_import? || message.deleted

    message.incoming? || message.outgoing?
  end

  def self.configured_inbox_id
    positive_id(ENV.fetch('RYZE_INBOX_ID', nil)) if ENV['RYZE_AUDIO_TRANSCRIPTION_ENABLED'] == 'true'
  end

  def self.pilot_setting
    ENV.fetch('RYZE_AUDIO_TRANSCRIPTION_CONVERSATION_ID', '')
  end

  def self.positive_id(value)
    id = Integer(value, 10, exception: false)
    id if id&.positive?
  end
  private_class_method :conversation_in_scope?, :same_account?, :eligible_message?, :configured_inbox_id, :pilot_setting, :positive_id

  def claim!
    with_lock do
      next unless pending? && next_attempt_at && next_attempt_at <= Time.current

      if attempts >= MAX_ATTEMPTS
        update!(status: :failed, next_attempt_at: nil)
        next
      end

      update!(attempts: attempts + 1, next_attempt_at: CLAIM_DURATION.from_now)
      attempts
    end
  end

  def finish!(attempt, result, text: nil)
    with_lock do
      next unless pending? && attempts == attempt

      next_status = result == :pending && attempt >= MAX_ATTEMPTS ? :failed : result
      update!(status: next_status, text: text, next_attempt_at: next_status == :pending ? RETRY_DELAY.from_now : nil)
    end
  end

  private

  def enqueue_processing
    Ryze::AudioTranscriptionJob.perform_later(id)
  rescue Redis::BaseError, RedisClient::Error, ConnectionPool::TimeoutError, ActiveJob::EnqueueError
    Rails.logger.warn("Ryze audio transcription #{id} could not be queued")
  end
end
