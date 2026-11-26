class Ryze::ConfirmOutgoingEditJob < ApplicationJob
  queue_as :medium
  discard_on ActiveRecord::RecordNotFound

  def perform(message_id, token, submitted_at, last_attempt: false)
    @claim = Ryze::EditClaim.new(message_id)
    return unless @claim.load_attempt(token)

    @message = Message.find(message_id)
    return unless original_eligible?

    text = Ryze::MessageProvider.new.text(@message.source_id)
    if @claim.requested?(text)
      confirm(text, submitted_at)
    elsif !last_attempt && text != :edit_unavailable && @claim.active?
      self.class.set(wait: 5.seconds).perform_later(message_id, token, submitted_at, last_attempt: true)
    end
  end

  private

  def original_eligible?
    @claim.original?(@message) && Ryze::OutgoingEditEligibility.new(@message).permitted?
  end

  def confirm(text, submitted_at)
    changed = @message.with_lock do
      next unless original_eligible? && @claim.active?

      Ryze::MessageEdit.apply(@message, content: text, edited_at: readback_revision(submitted_at))
    end
    @claim.release if changed
  end

  def readback_revision(submitted_at)
    # getMessage has no edit timestamp. A signed event in the command's
    # second (or later) takes precedence, even if it arrives after the GET.
    nanosecond = Rational(1, 1_000_000_000)
    floor = Time.at(submitted_at).utc - nanosecond
    previous = @message.additional_attributes['ryze_edited_at']
    return floor unless previous

    [floor, Time.iso8601(previous) + nanosecond].max
  end
end
