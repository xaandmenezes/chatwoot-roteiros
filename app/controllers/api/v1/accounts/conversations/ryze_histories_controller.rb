class Api::V1::Accounts::Conversations::RyzeHistoriesController < Api::V1::Accounts::Conversations::BaseController
  before_action :require_agent
  rescue_from Ryze::HistoricalSync::NotEnabled do
    head :not_found
  end
  rescue_from Ryze::HistoricalSync::UpstreamError, Net::OpenTimeout, Net::ReadTimeout, SocketError, JSON::ParserError do |e|
    render json: { error: e.message }, status: :bad_gateway
  end
  rescue_from Ryze::HistoricalSync::RateLimitError do |e|
    render json: { error: e.message }, status: :too_many_requests
  end

  def create
    @result = Ryze::HistoricalSync.new(conversation: @conversation, before: params[:before]).perform
    @messages = @result.imported_messages
    if Ryze::MessageReactions.pilot?(@conversation)
      source_ids = @messages.filter_map { |message| message.source_id if Ryze::MessageReactions.target?(message) }
      @unique_reaction_source_ids = Ryze::MessageReactions.unique_source_ids(@conversation, source_ids)
    end
    render :create
  rescue Ryze::HistoricalSync::InvalidCursor
    head :unprocessable_entity
  end

  def repair
    session = Ryze::HistoricalSync::Session.new(@conversation)
    message = @conversation.messages.history_imports.find(params[:message_id])
    session.media.repair_message(message)
    return head :bad_gateway if message.historical_media_pending?

    render json: message.agent_view_data(message.push_event_data, conversation: @conversation, viewer: Current.user)
  end

  private

  def require_agent
    head :not_found unless Current.user.is_a?(User)
  end
end
