class Ryze::EditOutgoingMessage
  MAX_CONTENT_LENGTH = 150_000

  def initialize(message:, conversation:, content:)
    @message = message
    @conversation = conversation
    @content = content
    @eligibility = Ryze::OutgoingEditEligibility.new(message, conversation: conversation)
    @claim = Ryze::EditClaim.new(message.id)
  end

  def perform
    # A replacement claim cannot take ownership while a readback is committing.
    error = @message.with_lock { claim_edit }
    return error if error

    perform_claimed
  end

  private

  def claim_edit
    return :invalid_content unless valid_content?
    return :edit_unavailable unless @eligibility.permitted? && @conversation.can_reply?
    return :edit_expired if @eligibility.expired?
    return :edit_pending unless @claim.acquire(@content, original: @message)

    nil
  end

  def perform_claimed
    outcome = edit_at_provider
  ensure
    @claim.release if outcome && outcome != :pending
  end

  def edit_at_provider
    provider = Ryze::EditProvider.new
    source_id = @message.source_id
    revision = previous_revision
    snapshot = provider.text(source_id)
    return snapshot unless snapshot.is_a?(String)
    return :edit_pending unless snapshot == previous_remote_text
    return :edit_unavailable unless @claim.original?(@message.reload) && @eligibility.permitted?
    return :edit_expired if @eligibility.expired?
    return :edit_pending unless @claim.active?

    submit_edit(provider, source_id, revision, snapshot)
  end

  def previous_remote_text
    previous_revision.present? ? @message.content : Messages::WebhookContentNormalizer.normalize(@message.content)
  end

  def submit_edit(provider, source_id, revision, snapshot)
    submitted_at = Time.current.to_i
    outcome = provider.request_edit(source_id, @content)
    return :confirmed if edit_confirmed?(source_id, revision)

    if outcome == :pending && snapshot != @content
      Ryze::ConfirmOutgoingEditJob.set(wait: 3.seconds).perform_later(@message.id, @claim.token, submitted_at)
    end
    outcome
  end

  def edit_confirmed?(source_id, revision)
    @message.reload
    @message.source_id == source_id && @message.content == @content &&
      previous_revision.present? && previous_revision != revision && !@message.deleted
  end

  def previous_revision
    @message.additional_attributes&.fetch('ryze_edited_at', nil)
  end

  def valid_content?
    @content.is_a?(String) && @content.present? && @content.length <= MAX_CONTENT_LENGTH && @content != @message.content
  end
end
