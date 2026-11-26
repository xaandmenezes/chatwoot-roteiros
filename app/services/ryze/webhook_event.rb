class Ryze::WebhookEvent
  def initialize(params)
    @params = params
    @data = params[:data]
    @message = @data[:message] if @data.is_a?(ActionController::Parameters)
  end

  def message_change?
    message_exchange? && @data[:direction] == 'incoming' &&
      (edited_message? || revoked_message?)
  end

  def outgoing_change?
    outgoing_edit? || outgoing_revoke? || tracked_delivery?
  end

  def outgoing_revoke?
    @data[:direction] == 'outgoing' && revoked_message? && revoke_type == 'sender_revoke'
  end

  def outgoing_edit?
    @data[:direction] == 'outgoing' && edited_message?
  end

  def tracked_delivery?
    @data[:direction] == 'outgoing' && @message[:type] == 'text' && tracking_source.is_a?(String) && tracking_source.start_with?('psr-cw-')
  end

  def tracking_source
    @message[:source]
  end

  def message_exchange?
    @params[:event] == 'message.exchange' && @message.is_a?(ActionController::Parameters)
  end

  def incoming_private_text?
    message_exchange? && @data[:direction] == 'incoming' && @message[:type] == 'text' &&
      @data[:chat].is_a?(ActionController::Parameters) && @data[:chat][:type] == 'private' &&
      source_id.is_a?(String) && source_id.present?
  end

  def pilot_log_line
    type = @message[:type]
    direction = @data[:direction]
    type = 'other' unless %w[text message_edit message_revoke protocol_message].include?(type)
    direction = 'unknown' unless %w[incoming outgoing].include?(direction)
    id_hash = source_id.is_a?(String) && source_id.present? ? Digest::SHA256.hexdigest(source_id).first(16) : 'missing'

    "Ryze pilot type=#{type} direction=#{direction} id_hash=#{id_hash}"
  end

  def instance_name
    instance_data = @params[:instanceData]
    instance_data[:instance] if instance_data.is_a?(ActionController::Parameters)
  end

  def valid?(require_chat: true)
    return false unless source_id.is_a?(String) && source_id.present?
    return false if require_chat && chat_ids.empty?
    return content.is_a?(String) && edited_at.present? if edited_message?

    %w[sender_revoke admin_revoke].include?(revoke_type)
  end

  def outside_pilot?(pilot_chat_id)
    pilot_chat_id.present? && chat_ids.exclude?(pilot_chat_id)
  end

  def customer_revoked?
    revoked_message? && revoke_type == 'sender_revoke'
  end

  def source_id
    @data[:id]
  end

  def chat_ids
    return [] unless @data[:chat].is_a?(ActionController::Parameters)

    [@data.dig(:chat, :jid), @data.dig(:chat, :lid)].select do |identifier|
      identifier.is_a?(String) && identifier.present?
    end
  end

  def content
    @message[:content] if edited_message? || tracked_delivery?
  end

  def edited_at
    return unless edited_message?

    edit = @message[:edit]
    edit_timestamp = edit[:timestamp] if edit.is_a?(ActionController::Parameters)

    parse_timestamp(edit_timestamp) || parse_timestamp(@data[:timestamp])
  end

  private

  def edited_message?
    @message.is_a?(ActionController::Parameters) && @message[:type] == 'message_edit' && @message[:isEdit] == true
  end

  def revoked_message?
    @message.is_a?(ActionController::Parameters) && @message[:type] == 'message_revoke'
  end

  def revoke_type
    revoke = @message[:revoke]
    revoke[:revokeType] if revoke.is_a?(ActionController::Parameters)
  end

  def parse_timestamp(value)
    return unless value.is_a?(String)

    Time.iso8601(value)
  rescue ArgumentError
    nil
  end
end
