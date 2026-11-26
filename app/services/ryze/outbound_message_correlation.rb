class Ryze::OutboundMessageCorrelation
  TRACKING_PREFIX = 'psr-cw-'.freeze
  TRACKING_PURPOSE = :ryze_outbound_delivery

  def self.find_tracked_message(inbox, source)
    return unless source.is_a?(String) && source.start_with?(TRACKING_PREFIX)

    message = Message.find_signed(source.delete_prefix(TRACKING_PREFIX), purpose: TRACKING_PURPOSE)
    message if message && message.inbox_id == inbox.id && message.account_id == inbox.account_id
  end

  def self.matching_message(conversation, source_id)
    matches = conversation.messages.where(source_id: source_id).limit(2).to_a
    return unless matches.one?

    message = matches.first
    message if message.additional_attributes&.fetch(Ryze::OutboundDelivery::VERIFIED_ID_KEY, nil) == source_id || native_mirror?(message)
  end

  def self.native_mirror?(message)
    Ryze::OutboundDelivery.native_mirror?(message) && message.sender_type == 'User' && message.sender_id == Ryze::OutboundDelivery.bridge_user_id
  end

  def initialize(message)
    @message = message
  end

  def tracking_source
    TRACKING_PREFIX + @message.signed_id(purpose: TRACKING_PURPOSE)
  end

  def confirm!(source_id, source, content)
    @message.conversation.with_lock do
      @message.with_lock { confirm_locked(source_id, source, content) }
    end
  end

  private

  def confirm_locked(source_id, source, content)
    return :ignored unless source == tracking_source && Ryze::OutboundDelivery.configured_for?(@message)
    return @message.source_id == source_id ? :confirmed : :conflict if delivery['state'] == 'confirmed'
    return :ignored unless expected_message?(content)

    coalesce!(source_id)
  end

  def expected_message?(content)
    %w[sending unknown].include?(delivery['state']) && !@message.deleted && @message.webhook_content == content
  end

  def coalesce!(source_id)
    return :conflict if @message.source_id.present? && @message.source_id != source_id

    matches = @message.conversation.messages.where(source_id: source_id).where.not(id: @message.id).limit(2).to_a
    return :conflict if matches.many? || (matches.one? && !safe_mirror?(matches.first))

    persist_confirmation(source_id, matches.first)
    :confirmed
  end

  def persist_confirmation(source_id, mirror)
    attributes = @message.additional_attributes.merge(
      Ryze::OutboundDelivery::DELIVERY_KEY => delivery.merge('state' => 'confirmed'),
      Ryze::OutboundDelivery::VERIFIED_ID_KEY => source_id
    )
    attributes[Ryze::OutboundDelivery::REPLACED_ID_KEY] = mirror.id if mirror
    states = [mirror&.status, @message.status]
    status = %w[read delivered].find { |state| states.include?(state) } || 'sent'
    mirror&.destroy!
    @message.update!(additional_attributes: attributes, source_id: source_id, external_error: nil, status: status)
  end

  def safe_mirror?(mirror)
    self.class.native_mirror?(mirror) && mirror.outgoing? && mirror.text? && !mirror.private? &&
      !mirror.deleted && same_content_without_dependencies?(mirror)
  end

  def same_content_without_dependencies?(mirror)
    mirror.webhook_content == @message.webhook_content && !mirror.attachments.exists? && !referenced?(mirror.id)
  end

  def referenced?(id)
    column = Message.arel_table[:content_attributes]
    # ActiveRecord::Store wraps this JSON column in serialized JSON.
    serialized = Arel::Nodes::InfixOperation.new('#>>', column, Arel::Nodes.build_quoted('{}'))
    attributes = Arel::Nodes::NamedFunction.new('CAST', [Arel::Nodes::Grouping.new(serialized).as('jsonb')])
    references = %w[in_reply_to forwarded_message_id].map do |attribute|
      Arel::Nodes::InfixOperation.new('->>', attributes, Arel::Nodes.build_quoted(attribute)).eq(id.to_s)
    end
    @message.conversation.messages.where(references.reduce(&:or)).exists?
  end

  def delivery
    @message.additional_attributes.fetch(Ryze::OutboundDelivery::DELIVERY_KEY)
  end
end
