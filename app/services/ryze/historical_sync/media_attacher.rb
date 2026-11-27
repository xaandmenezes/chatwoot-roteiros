require 'base64'
require 'stringio'

class Ryze::HistoricalSync::MediaAttacher
  MAX_MEDIA_BYTES = 15.megabytes
  # Base64 expansion plus room for provider JSON metadata.
  MAX_RESPONSE_BYTES = (((MAX_MEDIA_BYTES + 2) / 3) * 4) + 64.kilobytes
  MAX_DOWNLOADS = 4
  PENDING_KEY = 'ryze_history_pending_media'.freeze
  MEDIA_FIELDS = %w[mediaSize mediaMimeType mimeType mimetype fileName filename].freeze
  MEDIA_FILE_TYPES = {
    'image' => :image,
    'sticker' => :image,
    'video' => :video,
    'audio' => :audio,
    'ptt' => :audio,
    'document' => :file
  }.freeze

  def initialize(conversation:, client:, deadline:, locked_write:)
    @conversation = conversation
    @client = client
    @deadline = deadline
    @downloads = 0
    @locked_write = locked_write
  end

  def with_download(item, id, type)
    blob = download(item, id, type) if downloadable?(item, type) && @downloads < MAX_DOWNLOADS && Time.current < @deadline
    yield blob
  ensure
    # A concurrent importer may have won the conversation lock after our upload.
    blob.purge_later if blob && !blob.attachments.exists?
  end

  def assign(message, item, type, blob)
    unless MEDIA_FILE_TYPES.key?(type)
      message.content = item['content'].presence || item['text'].presence || item['caption'].presence
      return
    end

    message.content = item['caption'].presence || item['content'].presence
    return fallback(message, item, type) unless blob

    attach_blob(message, type, blob)
  end

  # One prior placeholder per run, independent of the current history cursor.
  def repair_pending
    pending = Arel::Nodes::InfixOperation.new('->', Message.arel_table[:additional_attributes], Arel::Nodes.build_quoted(PENDING_KEY))
    message = @conversation.messages.where(pending.not_eq(nil)).reorder(:updated_at, :id).first
    repair_message(message, rotate: true) if message
  end

  def repair_message(message, rotate: false)
    item = message.additional_attributes[PENDING_KEY]
    return message unless item

    type = item.fetch('type') unless message.deleted || message.attachments.exists?
    with_download(item, message.source_id, type) do |blob|
      @locked_write.call do
        message.with_lock { repair(message, item, blob, rotate: rotate) if message.additional_attributes[PENDING_KEY] == item }
      end
    end
    message
  end

  private

  def fallback(message, item, type)
    if downloadable?(item, type)
      message.additional_attributes[PENDING_KEY] = item.slice(*MEDIA_FIELDS).merge('type' => type, 'placeholder' => message.content.blank?)
    end
    message.content ||= I18n.t('conversations.messages.whatsapp.historical_media_unavailable', locale: @conversation.account.locale)
  end

  def attach_blob(message, type, blob)
    message.attachments.build(account: @conversation.account, file_type: MEDIA_FILE_TYPES.fetch(type)).file.attach(blob)
  end

  def repair(message, item, blob, rotate:)
    if !message.deleted && message.attachments.empty?
      # Rotate a failed retry behind the other placeholders.
      unless blob
        message.update!(updated_at: Time.current) if rotate
        return
      end

      attach_blob(message, item.fetch('type'), blob)
      message.content = nil if item.fetch('placeholder') && !message.additional_attributes['ryze_edited_at']
    end
    message.additional_attributes.delete(PENDING_KEY)
    message.save!
  end

  def downloadable?(item, type)
    MEDIA_FILE_TYPES.key?(type) && item['mediaSize'].to_i <= MAX_MEDIA_BYTES
  end

  def download(item, id, type)
    @downloads += 1
    payload = fetch_media_payload(id)
    return unless payload && Time.current < @deadline

    bytes = decode(payload.fetch('base64'), item['mediaSize'])
    return unless bytes

    file_type = MEDIA_FILE_TYPES.fetch(type)
    mime = media_mime_type(payload, item, file_type)
    filename = resolve_filename(item, id, mime, file_type)
    upload(bytes, filename, mime)
  rescue Ryze::Client::ConnectionError, JSON::ParserError, ArgumentError => e
    Rails.logger.warn("Ryze historical media download failed for #{id}: #{e.message}")
    nil
  end

  def upload(bytes, filename, mime)
    # Persist the key first so an interrupted storage upload can be purged.
    blob = ActiveStorage::Blob.create_before_direct_upload!(filename: filename, content_type: mime, byte_size: bytes.bytesize,
                                                            checksum: ActiveStorage.checksum_implementation.base64digest(bytes))
    remaining = @deadline - Time.current
    raise Timeout::Error, 'History upload deadline reached' unless remaining.positive?

    Timeout.timeout(remaining) { blob.upload(StringIO.new(bytes)) }
    blob.save!
    blob
  rescue StandardError => e
    blob&.purge_later
    Rails.logger.warn("Ryze historical media storage failed: #{e.class}")
    nil
  end

  def decode(encoded, declared_size)
    bytes = Base64.strict_decode64(encoded.delete("\r\n"))
    return if bytes.empty? || bytes.bytesize > MAX_MEDIA_BYTES
    return if declared_size.present? && bytes.bytesize != declared_size.to_i

    bytes
  end

  def fetch_media_payload(id)
    response = @client.get('chat/base64', messageId: id)
    raise Ryze::HistoricalSync::RateLimitError, "Ryze rate limit reached: #{response.code}" if response.code.to_i == 429
    return unless response.code.to_i.between?(200, 299)

    data = JSON.parse(response.body)
    data if data.is_a?(Hash) && data['success'] == true && data['base64'].is_a?(String)
  end

  def media_mime_type(payload, item, file_type)
    mime_type = payload.values_at('mime_type', 'mimeType', 'mimetype').compact_blank.first
    mime_type ||= item.values_at('mediaMimeType', 'mimeType', 'mimetype').compact_blank.first
    mime_type.to_s.split(';').first&.strip.presence || default_mime_type(file_type)
  end

  def resolve_filename(item, id, mime_type, file_type)
    filename = item['fileName'] || item['filename']
    return filename if filename.present?

    ext = Rack::Mime::MIME_TYPES.invert[mime_type] || default_extension(file_type)
    "#{file_type}_#{id}.#{ext.delete_prefix('.')}"
  end

  def default_extension(file_type)
    case file_type
    when :image then 'jpg'
    when :video then 'mp4'
    when :audio then 'ogg'
    else 'bin'
    end
  end

  def default_mime_type(file_type)
    case file_type
    when :image then 'image/jpeg'
    when :video then 'video/mp4'
    when :audio then 'audio/ogg'
    else 'application/octet-stream'
    end
  end
end
