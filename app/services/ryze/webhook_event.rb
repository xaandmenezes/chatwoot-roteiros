class Ryze::WebhookEvent
  def initialize(params)
    @params = params
    @data = params[:data]
    @message = @data[:message] if @data.is_a?(ActionController::Parameters)
  end

  def message_change?
    @params[:event] == 'message.exchange' && @data.is_a?(ActionController::Parameters) &&
      @message.is_a?(ActionController::Parameters) && @data[:direction] == 'incoming' &&
      (edited_message? || revoked_message?)
  end

  def instance_name
    instance_data = @params[:instanceData]
    instance_data[:instance] if instance_data.is_a?(ActionController::Parameters)
  end

  def valid?
    source_id.is_a?(String) && source_id.present? && chat_ids.any? &&
      (!edited_message? || (content.is_a?(String) && edited_at.present?))
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
    @message[:content] if edited_message?
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

  def parse_timestamp(value)
    return unless value.is_a?(String)

    Time.iso8601(value)
  rescue ArgumentError
    nil
  end
end
