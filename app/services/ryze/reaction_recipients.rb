class Ryze::ReactionRecipients
  def initialize(conversation)
    @conversation = conversation
    @account = conversation.account
  end

  def tokens
    members = @account.account_users
    inbox_members = @conversation.inbox.inbox_members.select(:user_id)
    candidates = members.where(user_id: inbox_members).or(members.administrator).includes(:user)
    candidates = candidates.includes(:custom_role) if AccountUser.reflect_on_association(:custom_role)
    participants = @conversation.conversation_participants.pluck(:user_id).to_set

    candidates.filter_map do |member|
      user = member.user
      context = { user: user, account: @account, account_user: member, inbox_access: true, conversation_participant: participants.include?(user.id) }
      user.pubsub_token if ConversationPolicy.new(context, @conversation).show?
    end
  end
end
