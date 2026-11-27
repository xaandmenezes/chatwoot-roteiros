class MessageFinder
  MESSAGE_ID_MAX = 2_147_483_647

  def initialize(conversation, params)
    @conversation = conversation
    @params = params
  end

  def perform
    current_messages
  end

  private

  def conversation_messages
    @conversation.messages.includes(:attachments, :sender, sender: { avatar_attachment: [:blob] })
  end

  def messages
    return conversation_messages if @params[:filter_internal_messages].blank?

    conversation_messages.where.not('private = ? OR message_type = ?', true, 2)
  end

  def current_messages
    return messages.none if oversized_message_id?(@params[:after])

    if @params[:after].present? && @params[:before].present?
      messages_between(normalized_message_id(@params[:after]), @params[:before].to_i)
    elsif @params[:before].present?
      messages_before(@params[:before].to_i)
    elsif @params[:after].present?
      messages_after(normalized_message_id(@params[:after]))
    else
      messages_latest
    end
  end

  def messages_after(after_id)
    messages.reorder('created_at asc').where('id > ?', after_id).limit(100)
  end

  def messages_before(before_id)
    return messages_latest if oversized_message_id?(before_id)

    scope = before_filter_scope(normalized_message_id(before_id))
    scope.reorder(created_at: :desc, id: :desc).limit(20).reverse
  end

  def before_filter_scope(before_id)
    cursor = @conversation.messages.select(:id, :created_at).find_by(id: before_id)
    return messages.where(Message.arel_table[:id].lt(before_id)) if cursor.blank?

    messages.where(cursor_condition(cursor))
  end

  def cursor_condition(cursor)
    arel = Message.arel_table
    arel[:created_at].lt(cursor.created_at).or(
      arel[:created_at].eq(cursor.created_at).and(arel[:id].lt(cursor.id))
    )
  end

  def messages_between(after_id, before_id)
    message_scope = messages.reorder('created_at asc').where('id >= ?', after_id)
    message_scope = message_scope.where('id < ?', normalized_message_id(before_id)) unless oversized_message_id?(before_id)
    message_scope.limit(1000)
  end

  def messages_latest
    messages.reorder(created_at: :desc, id: :desc).limit(20).reverse
  end

  def normalized_message_id(value)
    value.to_i.clamp(0, MESSAGE_ID_MAX)
  end

  def oversized_message_id?(value)
    value.to_i > MESSAGE_ID_MAX
  end
end

MessageFinder.prepend_mod_with('MessageFinder')
