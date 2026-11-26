class Ryze::MessageReactions
  KEY = 'ryze_reactions'.freeze

  def self.enabled?
    ENV['RYZE_REACTIONS_ENABLED'] == 'true'
  end

  def self.pilot?(conversation)
    enabled? && Ryze::OutgoingEditEligibility.pilot_conversation?(conversation)
  end

  def self.valid_emoji?(value)
    return false unless value.is_a?(String) && value.bytesize <= 128

    value.empty? || (value.match?(/\p{Emoji}/) && value.match?(/\A\X\z/) && !value.match?(/\A[0-9#*]\z/))
  end

  def self.target?(message)
    !message.private? && !message.deleted && (message.incoming? || message.outgoing?) &&
      Ryze::OutboundDelivery.provider_id?(message.source_id) && Ryze::OutgoingEditEligibility::EDITABLE_STATUSES.include?(message.status)
  end

  def self.originals(conversation, source_id)
    conversation.messages.where(account_id: conversation.account_id, inbox_id: conversation.inbox_id,
                                private: false, message_type: %i[incoming outgoing], source_id: source_id)
  end

  def self.sendable?(message, conversation: message.conversation)
    return false unless target?(message) && message.account_id == conversation.account_id && message.inbox_id == conversation.inbox_id
    return message.sender_type == 'Contact' && message.sender_id == conversation.contact_id if message.incoming?

    verified_outgoing?(message)
  end

  def self.verified_outgoing?(message)
    message.additional_attributes&.fetch(Ryze::OutboundDelivery::VERIFIED_ID_KEY, nil) == message.source_id ||
      Ryze::OutboundMessageCorrelation.native_mirror?(message)
  end
  private_class_method :verified_outgoing?

  def initialize(message)
    @message = message
  end

  def state
    @message.additional_attributes&.fetch(KEY, nil) || {}
  end

  def payload
    current = state
    {
      id: @message.id,
      conversation_id: @message.conversation.display_id,
      ryze_reactions: {
        revision: current.fetch('revision', 0),
        incoming: visible(current['incoming']),
        outgoing: visible(current['outgoing']),
        pending: current.key?('pending')
      }
    }
  end

  # Callers hold the original message lock while writing or comparing its state.
  def apply!(direction, attributes, source:)
    current = state.dup
    pending = matching_claim(direction, source, attributes['emoji'])
    previous = current[direction]
    advanced = newer?(previous, attributes, pending: pending)
    return unless advanced || pending

    if pending
      current.delete('pending')
      attributes = attributes.merge(pending.slice('author', 'agent_id'))
    end
    current[direction] = attributes if advanced
    write!(current)
  end

  def write!(value)
    updated = value.merge('revision' => state.fetch('revision', 0) + 1)
    # Reaction metadata has a dedicated agent event. A normal message save would also notify bridge, automation and contact clients.
    # rubocop:disable Rails/SkipsModelValidations
    @message.update_columns(additional_attributes: @message.additional_attributes.to_h.merge(KEY => updated))
    # rubocop:enable Rails/SkipsModelValidations
    data = payload
    Message.current_transaction.after_commit do
      Rails.configuration.dispatcher.sync_dispatcher.dispatch('message.ryze_reactions_changed', Time.current, { message: @message, payload: data })
    end
  end

  private

  def matching_claim(direction, source, emoji)
    pending = state['pending']
    pending if direction == 'outgoing' && pending&.values_at('source', 'emoji') == [source, emoji]
  end

  def visible(reaction)
    return if reaction.blank? || reaction['emoji'].empty?

    reaction.slice('emoji', 'author')
  end

  def newer?(previous, candidate, pending:)
    return true unless previous
    return false if previous['id'] == candidate['id']
    return true if previous['at'] < candidate['at']

    # Ordered, confirmed dashboard commands can share the same provider timestamp.
    previous['at'] == candidate['at'] && pending && pending['previous_id'] == previous['id']
  end
end
