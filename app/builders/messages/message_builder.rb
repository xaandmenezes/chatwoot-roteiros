class Messages::MessageBuilder
  include ::FileTypeHelper
  include ::EmailHelper
  include ::DataHelper

  attr_reader :message

  def initialize(user, conversation, params, api_token_request: nil)
    @params = params
    @api_token_request = api_token_request
    @private = ActiveModel::Type::Boolean.new.cast(params[:private]) || false
    @conversation = conversation
    @user = user
    @account = conversation.account
    @message_type = params[:message_type] || 'outgoing'
    @attachments = params[:attachments]
    @is_voice_message = ActiveModel::Type::Boolean.new.cast(params[:is_voice_message])
    @voice_indices = parse_voice_message_attachment_indices(params[:voice_message_attachment_indices])
    @automation_rule = content_attributes&.dig(:automation_rule_id)
    return unless params.instance_of?(ActionController::Parameters)

    @in_reply_to = content_attributes&.dig(:in_reply_to)
    @items = content_attributes&.dig(:items)
  end

  def perform(replay_incoming_attachments: false)
    return receive_native_mirror if native_mirror?
    return create_message unless replayable_incoming_delivery?
    return replay_incoming_attachments ? receive_incoming_attachments : create_message if @attachments.present?

    @conversation.with_lock do
      @message = existing_incoming_text || create_message
      @message.echo_id = @params[:echo_id]
      @message
    end
  end

  private

  def native_mirror?
    @api_token_request == true && plain_outgoing_text? && Ryze::OutboundDelivery.provider_id?(@params[:source_id]) &&
      Ryze::OutboundDelivery.bridge_user?(@user) && Ryze::OutboundDelivery.configured_pilot?(@conversation)
  end

  def direct_outgoing?
    return false unless @api_token_request == false && @user.is_a?(User) && @params[:source_id].blank?
    return false unless plain_outgoing_text? && ordinary_dashboard_text?
    return false if conversation_auto_translates?

    Ryze::OutboundDelivery.configured_pilot?(@conversation)
  end

  def plain_outgoing_text?
    @message_type == 'outgoing' && !@private && plain_text_delivery? && @params[:content].is_a?(String) && @params[:content].present? &&
      content_attributes.values_at(:in_reply_to, :in_reply_to_external_id).all?(&:blank?)
  end

  def ordinary_dashboard_text?
    @params.values_at(:campaign_id, :template_params, :external_created_at, :email_html_content).all?(&:blank?) &&
      content_attributes.values.all?(&:blank?)
  end

  def conversation_auto_translates?
    @conversation.respond_to?(:auto_translate_enabled?) && @conversation.auto_translate_enabled?
  end

  def receive_native_mirror
    mirror = Ryze::ReactionMirror.new(conversation: @conversation, provider_id: @params[:source_id])
    @message = mirror.receive(content: @params[:content]) do
      Ryze::OutboundMessageCorrelation.matching_message(@conversation, @params[:source_id]) || create_message(native_mirror: true)
    end
  end

  def replayable_incoming_delivery?
    return false unless @message_type == 'incoming' && !@private && @conversation.inbox.api?
    return false unless text_content_delivery?

    @params[:source_id].is_a?(String) && @params[:source_id].present?
  end

  def text_content_delivery?
    [nil, 'text'].include?(@params[:content_type]) && forwarded_message_id.blank?
  end

  def plain_text_delivery?
    @attachments.blank? && text_content_delivery?
  end

  def existing_incoming_text
    candidates = incoming_delivery_candidates.left_joins(:attachments)
    text = candidates.where(attachments: { id: nil }).where(Messages::IncomingAttachmentReplay.fingerprint_attribute.eq(nil))
    text.or(candidates.history_imports).reorder(:id).first
  end

  def incoming_delivery_candidates
    @conversation.messages.incoming.where(private: false, content_type: :text, source_id: @params[:source_id])
  end

  def receive_incoming_attachments
    uploads = Array(@attachments)
    raise ArgumentError, 'attachments exceeded maximum allowed' if uploads.size > Message::NUMBER_OF_PERMITTED_ATTACHMENTS

    message = build_message
    candidates = incoming_delivery_candidates.where(account_id: message.account_id, inbox_id: message.inbox_id)
    @message = Messages::IncomingAttachmentReplay.new(message, uploads, candidates).perform
    @message.echo_id = @params[:echo_id]
    @message
  end

  def create_message(native_mirror: false)
    build_message
    mark_ryze_delivery(native_mirror)
    @message.save!
    @message
  end

  def build_message
    @message = @conversation.messages.build(message_params)
    process_attachments
    process_emails
    # When the message has no quoted content, it will just be rendered as a regular message
    # The frontend is equipped to handle this case
    process_email_content
    @message
  end

  def mark_ryze_delivery(native_mirror)
    return unless @message.sender_type == 'User' && @message.sender_id == @user&.id

    if native_mirror
      @message.additional_attributes = (@message.additional_attributes || {}).merge(Ryze::OutboundDelivery::MIRROR_KEY => true)
    elsif direct_outgoing?
      Ryze::OutboundDelivery.prepare(@message)
    end
  end

  # Extracts content attributes from the given params.
  # - Converts ActionController::Parameters to a regular hash if needed.
  # - Attempts to parse a JSON string if content is a string.
  # - Returns an empty hash if content is not present, if there's a parsing error, or if it's an unexpected type.
  def content_attributes
    params = convert_to_hash(@params)
    content_attributes = params.fetch(:content_attributes, {})

    return safe_parse_json(content_attributes) if content_attributes.is_a?(String)
    return content_attributes if content_attributes.is_a?(Hash)

    {}
  end

  def process_attachments
    (Array(@attachments) + forwarded_attachments).each_with_index do |uploaded_attachment, index|
      attachment = @message.attachments.build(
        account_id: @message.account_id,
        file: uploaded_attachment
      )

      attachment.file_type = attachment_file_type(uploaded_attachment)
      tag_voice_message(attachment, index)
    end
  end

  def attachment_file_type(uploaded_attachment)
    if uploaded_attachment.is_a?(String)
      file_type_by_signed_id(uploaded_attachment)
    else
      file_type(uploaded_attachment&.content_type)
    end
  end

  def parse_voice_message_attachment_indices(indices)
    return if indices.nil?

    valid_positions = Array(@attachments).each_index.map(&:to_s)
    unless indices.is_a?(Array) && (indices.map(&:to_s) - valid_positions).empty?
      raise ArgumentError, 'voice_message_attachment_indices must be an array of valid attachment positions'
    end

    indices.to_set(&:to_i)
  end

  def tag_voice_message(attachment, index)
    return unless attachment.audio?

    recorded = @voice_indices ? @voice_indices.include?(index) : @is_voice_message
    return unless recorded

    attachment.meta = (attachment.meta || {}).merge('is_voice_message' => true)
  end

  def forwarded_message_id
    content_attributes[:forwarded_message_id]
  end

  def forwarded_attachments
    return [] if forwarded_message_id.blank?

    forwarded_message = @conversation.messages.find(forwarded_message_id)
    forwarded_message.attachments.where(id: @params[:forwarded_attachment_ids]).map { |attachment| attachment.file.blob }
  end

  def validate_forward
    return if forwarded_message_id.blank?

    raise StandardError, 'Forwarded emails need an email inbox' unless @conversation.inbox.email?
    raise StandardError, 'Forwarded emails cannot be private' if @private
    raise StandardError, 'Forwarded emails need a recipient' if process_email_string(@params[:to_emails]).empty?
  end

  def process_emails
    validate_forward
    return unless @conversation.inbox&.inbox_type == 'Email'

    cc_emails = process_email_string(@params[:cc_emails])
    bcc_emails = process_email_string(@params[:bcc_emails])
    to_emails = process_email_string(@params[:to_emails])

    all_email_addresses = cc_emails + bcc_emails + to_emails
    validate_email_addresses(all_email_addresses)

    @message.content_attributes[:cc_emails] = cc_emails
    @message.content_attributes[:bcc_emails] = bcc_emails
    @message.content_attributes[:to_emails] = to_emails
    @message.content_attributes[:email] = { subject: @params[:subject] } if @params[:subject].present? && !@private
  end

  def process_email_content
    return unless should_process_email_content?

    @message.content_attributes ||= {}
    email_attributes = build_email_attributes
    @message.content_attributes[:email] = email_attributes
  end

  def process_email_string(email_string)
    return [] if email_string.blank?

    email_string.gsub(/\s+/, '').split(',')
  end

  def message_type
    if @conversation.inbox.channel_type != 'Channel::Api' && @message_type == 'incoming'
      raise StandardError, 'Incoming messages are only allowed in Api inboxes'
    end

    @message_type
  end

  def sender
    message_type == 'outgoing' ? (message_sender || @user) : @conversation.contact
  end

  def external_created_at
    @params[:external_created_at].present? ? { external_created_at: @params[:external_created_at] } : {}
  end

  def automation_rule_id
    @automation_rule.present? ? { content_attributes: { automation_rule_id: @automation_rule } } : {}
  end

  def campaign_id
    @params[:campaign_id].present? ? { additional_attributes: { campaign_id: @params[:campaign_id] } } : {}
  end

  def template_params
    @params[:template_params].present? ? { additional_attributes: { template_params: JSON.parse(@params[:template_params].to_json) } } : {}
  end

  def message_sender
    return if @params[:sender_type] != 'AgentBot'

    AgentBot.where(account_id: [nil, @conversation.account.id]).find_by(id: @params[:sender_id])
  end

  def message_params
    {
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      message_type: message_type,
      content: @params[:content],
      private: @private,
      sender: sender,
      content_type: @params[:content_type],
      content_attributes: content_attributes.presence,
      items: @items,
      in_reply_to: @in_reply_to,
      echo_id: @params[:echo_id],
      source_id: @params[:source_id]
    }.merge(external_created_at).merge(automation_rule_id).merge(campaign_id).merge(template_params)
  end

  def email_inbox?
    @conversation.inbox&.inbox_type == 'Email'
  end

  def should_process_email_content?
    email_inbox? && !@private && @message.content.present?
  end

  def build_email_attributes
    email_attributes = ensure_indifferent_access(@message.content_attributes[:email] || {})
    normalized_content = normalize_email_body(@message.content)

    # Process liquid templates in normalized content with code block protection
    processed_content = process_liquid_in_email_body(normalized_content)

    # Use custom HTML content if provided, otherwise generate from message content
    email_attributes[:html_content] = if custom_email_content_provided?
                                        build_custom_html_content
                                      else
                                        build_html_content(processed_content)
                                      end

    email_attributes[:text_content] = build_text_content(processed_content)
    email_attributes
  end

  def build_html_content(normalized_content)
    html_content = ensure_indifferent_access(@message.content_attributes.dig(:email, :html_content) || {})
    rendered_html = render_email_html(normalized_content)
    html_content[:full] = rendered_html
    html_content[:reply] = rendered_html
    html_content
  end

  def build_text_content(normalized_content)
    text_content = ensure_indifferent_access(@message.content_attributes.dig(:email, :text_content) || {})
    text_content[:full] = normalized_content
    text_content[:reply] = normalized_content
    text_content
  end

  def custom_email_content_provided?
    @params[:email_html_content].present?
  end

  def build_custom_html_content
    html_content = ensure_indifferent_access(@message.content_attributes.dig(:email, :html_content) || {})

    html_content[:full] = @params[:email_html_content]
    html_content[:reply] = @params[:email_html_content]

    html_content
  end

  # Liquid processing methods for email content
  def process_liquid_in_email_body(content)
    return content if content.blank?
    return content unless should_process_liquid?

    # Protect code blocks from liquid processing
    modified_content = modified_liquid_content(content)
    template = Liquid::Template.parse(modified_content)
    template.render(drops_with_sender)
  rescue Liquid::Error
    content
  end

  def should_process_liquid?
    @message_type == 'outgoing' || @message_type == 'template'
  end

  def drops_with_sender
    message_drops(@conversation).merge({
                                         'agent' => UserDrop.new(sender)
                                       })
  end
end

Messages::MessageBuilder.prepend_mod_with('Messages::MessageBuilder')
