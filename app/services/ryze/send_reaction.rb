class Ryze::SendReaction
  REMOVAL_RECEIPT = 'Reaction removed successfully'.freeze

  def initialize(message:, actor:, emoji:)
    @message = message
    @actor = actor
    @emoji = emoji
    @reactions = Ryze::MessageReactions.new(message)
  end

  def perform
    return :invalid_reaction unless Ryze::MessageReactions.valid_emoji?(@emoji)

    result = claim
    return result unless result == :claimed

    request_reaction
  rescue Ryze::Client::ConnectionError, JSON::ParserError
    confirm(nil)
  end

  private

  def claim
    @message.with_lock do
      next :reaction_unavailable unless eligible_target?

      state = @reactions.state
      next :pending if state.key?('pending')
      next :confirmed if state.dig('outgoing', 'emoji').to_s == @emoji

      @source = "psr-cw-reaction-#{SecureRandom.hex(16)}"
      @target_id = @message.source_id
      @target_outgoing = @message.outgoing?
      @chat_jid = Ryze::OutgoingEditEligibility.conversation_jid(@message.conversation)
      next :reaction_unavailable unless @chat_jid

      pending = {
        'source' => @source, 'emoji' => @emoji, 'author' => @actor.name, 'agent_id' => @actor.id, 'previous_id' => state.dig('outgoing', 'id')
      }
      @reactions.write!(state.merge('pending' => pending))
      :claimed
    end
  end

  def eligible_target?
    conversation = @message.conversation
    Ryze::MessageReactions.pilot?(conversation) && Ryze::MessageReactions.sendable?(@message, conversation: conversation)
  end

  def request_reaction
    instance = ENV.fetch('RYZE_INSTANCE_NAME')
    client = Ryze::Client.new(instance: instance, token: ENV.fetch('RYZE_EDIT_API_TOKEN'))
    response = client.post('message/reaction', { number: @chat_jid, messageId: @target_id, reaction: @emoji.presence || 'remove',
                                                 fromMe: @target_outgoing, source: @source })
    return reject if Ryze::OutboundDelivery::REJECTED_CODES.include?(response.code)

    confirmation = acknowledgment(response, instance) if response.code == '200'
    confirm(confirmation)
  end

  def acknowledgment(response, instance)
    body = accepted_receipt(response)
    return unless body

    data = body['data']
    return unless matches_command?(data) && matches_session?(data, instance)
    return unless matches_content?(data['content'], body['message'])

    timestamp = data['timestamp']
    return unless timestamp.is_a?(String)

    { 'id' => data['messageId'], 'emoji' => @emoji, 'at' => Time.iso8601(timestamp).utc.iso8601(9) }
  rescue ArgumentError
    nil
  end

  def accepted_receipt(response)
    body = JSON.parse(response.body)
    body if body.is_a?(Hash) && body.values_at('success', 'status') == [true, 'sent']
  end

  def matches_content?(content, receipt)
    content == @emoji || (@emoji.empty? && content.nil? && receipt == REMOVAL_RECEIPT)
  end

  def matches_command?(data)
    data.is_a?(Hash) && data.values_at('direction', 'messageType', 'source') == ['sent', 'reaction', @source] &&
      Ryze::OutboundDelivery.provider_id?(data['messageId']) && data['messageId'] != @target_id &&
      data['replyTo'].is_a?(Hash) && data['replyTo']['messageId'] == @target_id
  end

  def matches_session?(data, instance)
    data['chat'].is_a?(Hash) && data['chat'].values_at('jid', 'isGroup') == [@chat_jid, false] &&
      data['sender'].is_a?(Hash) && data['sender']['instance'] == instance
  end

  def confirm(attributes)
    conversation = @message.conversation
    conversation.with_lock do
      @message.with_lock do
        next :confirmed unless pending?
        next :pending unless attributes

        echo = Ryze::ReactionMirror.new(conversation: conversation, provider_id: attributes.fetch('id'))
        receipt = echo.record!(target_id: @target_id, emoji: @emoji)
        next :pending if receipt == :conflict

        @reactions.apply!('outgoing', attributes, source: @source, replayed: receipt == :replayed)
        :confirmed
      end
    end
  end

  def reject
    @message.with_lock do
      next :confirmed unless pending?

      @reactions.write!(@reactions.state.except('pending'))
      :reaction_failed
    end
  end

  def pending?
    @reactions.state.dig('pending', 'source') == @source
  end
end
