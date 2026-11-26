class UmblerLabels::BatchJob < ApplicationJob
  queue_as :low

  BATCH_SIZE = 20

  def perform(run_id)
    @run = UmblerLabelSync.find_by(id: run_id)
    return unless @run

    @claimed = claim_batch
    return unless @claimed

    if UmblerLabels::Sync.configured?(@run.account)
      process_batch
    else
      @run.fail_if!('running')
    end
  rescue UmblerLabels::Client::Error => e
    Rails.logger.warn("Umbler label sync #{run_id} stopped (#{e.class.name})")
    @run.fail_if!('running') if @claimed
  rescue StandardError
    @run.fail_if!('running') if @claimed
    raise
  end

  private

  def process_batch
    contacts = @run.account.contacts.where(id: (@run.cursor + 1)..@run.last_contact_id).order(:id).limit(BATCH_SIZE + 1).to_a
    sync = UmblerLabels::Sync.new(@run.account)
    processed = contacts.first(BATCH_SIZE).all? { |contact| record_result(contact.id, sync.call(contact).to_s) }
    finish_batch(contacts.size > BATCH_SIZE) if processed
  end

  def claim_batch
    @run.with_lock do
      return false unless @run.queued?

      @run.update!(status: :running)
    end
  end

  def record_result(contact_id, result)
    raise ArgumentError, 'Unknown label sync outcome' unless UmblerLabelSync::OUTCOMES.include?(result)

    @run.with_lock do
      return false unless @run.running?

      counts = @run.counts
      counts[result] = counts.fetch(result, 0) + 1
      counts['processed'] = counts.fetch('processed', 0) + 1
      @run.update!(counts: counts, cursor: contact_id)
    end
  end

  def finish_batch(more_contacts)
    @run.with_lock do
      return unless @run.running?

      @run.update!(status: more_contacts ? :queued : :completed)
    end
    @run.enqueue_batch if more_contacts
  end
end
