module Enterprise::SearchService
  ADVANCED_SEARCH_GROUP_DENIAL_LIMIT = 1000

  def advanced_search
    where_conditions = build_where_conditions
    apply_filters(where_conditions)

    denied_group_ids = advanced_search_denied_group_ids(where_conditions)
    return filter_messages_with_like if denied_group_ids.size > ADVANCED_SEARCH_GROUP_DENIAL_LIMIT

    where_conditions[:conversation_id] = { not: denied_group_ids } if denied_group_ids.present?
    Message.search(
      search_query,
      fields: %w[content attachments.transcribed_text content_attributes.email.subject],
      where: where_conditions,
      # id breaks created_at ties so results stay stable across page fetches;
      # unmapped_type covers documents indexed before id was added
      order: { created_at: :desc, id: { order: :desc, unmapped_type: 'long' } },
      page: params[:page] || 1,
      per_page: 15
    )
  end

  private

  def conversation_base_query
    exclude_hidden_whatsapp_groups(super, :id)
  end

  def message_base_query
    exclude_hidden_whatsapp_groups(super, :conversation_id)
  end

  def exclude_hidden_whatsapp_groups(query, column)
    return query unless restricted_whatsapp_group_inbox

    query.where.not(column => hidden_whatsapp_groups.select(:id))
  end

  def hidden_whatsapp_groups
    groups = Ryze::GroupConversations.scope(current_account)
    accessible_groups = Conversations::PermissionFilterService.new(groups, current_user, current_account).perform
    groups.where.not(id: accessible_groups.select(:id))
  end

  def advanced_search_denied_group_ids(where_conditions)
    inbox = restricted_whatsapp_group_inbox
    return [] unless inbox
    return [] if where_conditions[:inbox_id].present? && Array(where_conditions[:inbox_id]).exclude?(inbox.id)

    # One extra row detects overflow so the SQL fallback can enforce the full denial.
    hidden_whatsapp_groups.limit(ADVANCED_SEARCH_GROUP_DENIAL_LIMIT + 1).ids
  end

  def restricted_whatsapp_group_inbox
    return @restricted_whatsapp_group_inbox if defined?(@restricted_whatsapp_group_inbox)

    inbox = Ryze::GroupConversations.inbox(current_account)
    eligible = inbox && accessable_inbox_ids.include?(inbox.id) && restricted_group_role?
    @restricted_whatsapp_group_inbox = eligible ? inbox : nil
  end

  def restricted_group_role?
    account_user&.agent? && account_user.custom_role_id.present? && account_user.permissions.exclude?('conversation_manage')
  end

  def build_where_conditions
    conditions = { account_id: current_account.id }
    conditions[:inbox_id] = accessable_inbox_ids unless should_skip_inbox_filtering?
    conditions
  end

  def apply_filters(where_conditions)
    apply_from_filter(where_conditions)
    apply_time_range_filter(where_conditions)
    apply_inbox_filter(where_conditions)
  end

  def apply_from_filter(where_conditions)
    sender_type, sender_id = parse_from_param(params[:from])
    return unless sender_type && sender_id

    where_conditions[:sender_type] = sender_type
    where_conditions[:sender_id] = sender_id
  end

  def parse_from_param(from_param)
    return [nil, nil] unless from_param&.match?(/\A(contact|agent):\d+\z/)

    type, id = from_param.split(':')
    sender_type = type == 'agent' ? 'User' : 'Contact'
    [sender_type, id.to_i]
  end

  def apply_time_range_filter(where_conditions)
    time_conditions = {}
    time_conditions[:gte] = enforce_time_limit(params[:since])
    time_conditions[:lte] = cap_until_time(params[:until]) if params[:until].present?

    where_conditions[:created_at] = time_conditions if time_conditions.any?
  end

  def enforce_time_limit(since_param)
    since_param.present? ? cap_since_time(since_param) : search_window_start
  end

  def apply_inbox_filter(where_conditions)
    return if params[:inbox_id].blank?

    inbox_id = params[:inbox_id].to_i
    return if inbox_id.zero?
    return unless validate_inbox_access(inbox_id)

    where_conditions[:inbox_id] = inbox_id
  end

  def validate_inbox_access(inbox_id)
    return true if should_skip_inbox_filtering?

    accessable_inbox_ids.include?(inbox_id)
  end
end
