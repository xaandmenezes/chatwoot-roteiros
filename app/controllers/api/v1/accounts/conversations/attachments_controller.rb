class Api::V1::Accounts::Conversations::AttachmentsController < Api::V1::Accounts::Conversations::BaseController
  include ActiveStorage::Streaming

  # Native image/audio tags send the existing dashboard cookie rather than axios headers.
  prepend_before_action :no_store, :read_dashboard_credentials

  def show
    attachment = conversation_attachment
    return head :not_found unless attachment.file.attached?

    stream_attachment(attachment.file.blob)
  end

  private

  def conversation_attachment
    files = Attachment.where(account_id: Current.account.id, message_id: @conversation.messages.select(:id))
    files.with_attached_file.find(params[:id])
  end

  def stream_attachment(blob)
    if params[:thumbnail] == 'true' && blob.representable?
      send_blob_stream(blob.representation(resize_to_fill: [250, nil]).processed, disposition: :inline)
    elsif request.headers['Range'].present?
      send_blob_byte_range_data(blob, request.headers['Range'], disposition: disposition)
    else
      stream_original(blob)
    end
  end

  def stream_original(blob)
    response.headers['Accept-Ranges'] = 'bytes'
    response.headers['Content-Length'] = blob.byte_size.to_s
    send_blob_stream(blob, disposition: disposition)
  end

  def disposition
    params[:disposition] if %w[inline attachment].include?(params[:disposition])
  end

  def read_dashboard_credentials
    raw = cookies['cw_d_session_info']
    return if raw.blank? || explicit_credentials?

    credentials = JSON.parse(raw)
    return unless credentials.is_a?(Hash)

    %w[access-token client uid].each { |key| request.headers[key] = credentials[key] if credentials[key].is_a?(String) }
  rescue JSON::ParserError
    nil
  end

  def explicit_credentials?
    request.authorization.present? || request.headers['access-token'].present? || authenticate_by_access_token?
  end
end
