class Api::V1::Accounts::Conversations::RyzeHistoriesController < Api::V1::Accounts::Conversations::BaseController
  def create
    return head :not_found unless Current.user.is_a?(User) && Ryze::HistoricalSync.enabled?(@conversation)

    @result = Ryze::HistoricalSync.new(conversation: @conversation, before: params[:before]).perform
    @messages = @result.imported_messages
    if Ryze::MessageReactions.pilot?(@conversation)
      source_ids = @messages.filter_map { |message| message.source_id if Ryze::MessageReactions.target?(message) }
      @unique_reaction_source_ids = Ryze::MessageReactions.unique_source_ids(@conversation, source_ids)
    end
    render :create
  rescue Ryze::HistoricalSync::RateLimitError => e
    render json: { error: e.message }, status: :too_many_requests
  rescue Ryze::HistoricalSync::UpstreamError, Net::OpenTimeout, Net::ReadTimeout, SocketError, JSON::ParserError => e
    render json: { error: e.message }, status: :bad_gateway
  end
end
