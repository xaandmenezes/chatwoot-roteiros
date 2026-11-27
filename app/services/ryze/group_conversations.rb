class Ryze::GroupConversations
  GROUP_JID = /\A[0-9]+(-[0-9]+)?@g\.us\z/
  SCOPES = %w[groups inbox].freeze

  class << self
    def enabled_inbox?(inbox)
      !!(inbox && inbox.id == configured_inbox_id && inbox.api?)
    end

    def inbox(account)
      inbox_id = configured_inbox_id
      Inbox.find_by(account: account, id: inbox_id, channel_type: 'Channel::Api') if inbox_id
    end

    def inbox_for_contact_change(contact)
      target = inbox(contact.account_id)
      return unless target

      bindings = ContactInbox.arel_table
      affected = contact.conversations.where(account_id: contact.account_id, inbox_id: target.id)
                        .joins(:contact_inbox)
                        .where(contact_inboxes: { contact_id: contact.id, inbox_id: target.id })
                        .where(group_jid_predicate(bindings[:source_id]))
      target if affected.exists?
    end

    def inbox_for_source_change(binding)
      return unless binding.inbox_id == configured_inbox_id
      return unless binding.saved_change_to_source_id.any? { |jid| GROUP_JID.match?(jid) }

      target = binding.inbox
      return unless enabled_inbox?(target)

      target if binding.conversations.exists?(account_id: target.account_id, inbox_id: target.id, contact_id: binding.contact_id)
    end

    def scope(account)
      inbox_id = configured_inbox_id
      return Conversation.none unless inbox_id

      inbox_ids = account.inboxes.where(id: inbox_id, channel_type: 'Channel::Api').select(:id)
      account.conversations.where(inbox_id: inbox_ids).joins(:contact_inbox, :contact).where(group_predicate)
    end

    def filter(conversations, account:, scope:)
      case scope
      when 'groups'
        conversations.where(id: self.scope(account).select(:id))
      when 'inbox'
        configured_inbox_id ? conversations.where.not(id: self.scope(account).select(:id)) : conversations
      else
        conversations
      end
    end

    def group?(conversation)
      inbox_id = configured_inbox_id
      return false unless inbox_id && conversation.inbox_id == inbox_id
      return false unless enabled_inbox?(conversation.inbox) && conversation.inbox.account_id == conversation.account_id
      return false unless same_contact_binding?(conversation)

      matching_group_identifiers?(conversation)
    end

    private

    def same_contact_binding?(conversation)
      binding = conversation.contact_inbox
      contact = conversation.contact
      return false unless binding && contact

      binding.inbox_id == conversation.inbox_id && binding.contact_id == contact.id && contact.account_id == conversation.account_id
    end

    def matching_group_identifiers?(conversation)
      group_jid = conversation.contact_inbox.source_id
      return false unless GROUP_JID.match?(group_jid)

      identifiers = [conversation.contact.identifier, conversation.additional_attributes&.[]('whatsapp_jid')].compact
      identifiers.reject! { |identifier| identifier == '' }
      identifiers.present? && identifiers.all?(group_jid)
    end

    def configured_inbox_id
      return unless ENV['RYZE_GROUPS_INBOX_ENABLED'] == 'true'

      Integer(ENV.fetch('RYZE_INBOX_ID', ''), 10, exception: false)
    end

    def group_predicate
      conversations = Conversation.arel_table
      bindings = ContactInbox.arel_table
      contacts = Contact.arel_table
      conversation_jid = Arel::Nodes::InfixOperation.new('->>', conversations[:additional_attributes], Arel::Nodes.build_quoted('whatsapp_jid'))

      bindings[:inbox_id].eq(conversations[:inbox_id])
                         .and(bindings[:contact_id].eq(conversations[:contact_id]))
                         .and(contacts[:account_id].eq(conversations[:account_id]))
                         .and(matching_group_predicate(bindings[:source_id], contacts[:identifier], conversation_jid))
    end

    def matching_group_predicate(group_jid, contact_identifier, conversation_jid)
      format_matches = group_jid_predicate(group_jid)
      format_matches.and(contact_identifier.eq(group_jid).or(conversation_jid.eq(group_jid)))
                    .and(matching_or_unset(contact_identifier, group_jid))
                    .and(matching_or_unset(conversation_jid, group_jid))
    end

    def group_jid_predicate(attribute)
      # PostgreSQL spells the end-of-string anchor as \Z.
      pattern = Arel::Nodes.build_quoted(GROUP_JID.source.sub(/\\z\z/, '\\Z'))
      Arel::Nodes::InfixOperation.new('~', attribute, pattern)
    end

    def matching_or_unset(attribute, group_jid)
      attribute.eq(group_jid).or(attribute.eq(nil)).or(attribute.eq(''))
    end
  end
end
