require 'base64'
require 'stringio'

class Ryze::HistoricalSync::MediaAttacher
  MAX_MEDIA_BYTES = 15.megabytes
  MEDIA_FILE_TYPES = {
    'image' => :image,
    'sticker' => :image,
    'video' => :video,
    'audio' => :audio,
    'ptt' => :audio,
    'document' => :file
  }.freeze

  def initialize(conversation:, client:)
    @conversation = conversation
    @client = client
  end

  def attach(message, item, id, type)
    if MEDIA_FILE_TYPES.key?(type)
      attach_media(message, item, id, type)
    else
      message.content = item['content'].presence || item['text'].presence || item['caption'].presence
    end
  end

  private

  def attach_media(message, item, id, type)
    attached = false
    media_size = item['mediaSize'].to_i
    attached = download_and_attach(message, item, id, type) if media_size <= MAX_MEDIA_BYTES

    fallback = item['caption'].presence || item['content'].presence
    fallback ||= '[Mídia histórica indisponível]' unless attached
    message.content = fallback if message.content.blank?
  end

  def download_and_attach(message, item, id, type)
    payload = fetch_media_payload(id)
    return false unless payload

    file_type = MEDIA_FILE_TYPES[type]
    clean_mime = clean_mime_type(payload['mime_type'] || item['mediaMimeType'] || item['mimeType'] || item['mimetype'], file_type)
    filename = resolve_filename(item, id, clean_mime, file_type)

    attachment = message.attachments.build(account: @conversation.account, file_type: file_type)
    attachment.file.attach(io: StringIO.new(payload['decoded']), filename: filename, content_type: clean_mime)
    true
  rescue Ryze::HistoricalSync::RateLimitError
    raise
  rescue StandardError => e
    Rails.logger.warn("Ryze historical media download failed for #{id}: #{e.message}")
    false
  end

  def fetch_media_payload(id)
    response = @client.get('chat/base64', messageId: id)
    raise Ryze::HistoricalSync::RateLimitError, "Ryze rate limit reached: #{response.code}" if response.code.to_i == 429
    return unless response.code.to_i.between?(200, 299)

    data = JSON.parse(response.body)
    return unless data['success'] && data['base64'].present?

    {
      'decoded' => Base64.decode64(data['base64']),
      'mime_type' => data['mime_type'] || data['mimeType'] || data['mimetype']
    }
  end

  def clean_mime_type(mime_type, file_type)
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
