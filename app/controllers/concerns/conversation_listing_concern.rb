module ConversationListingConcern
  extend ActiveSupport::Concern

  COLLECTION_ACTIONS = [:index, :meta, :search, :filter].freeze

  included do
    before_action :validate_whatsapp_scope, only: COLLECTION_ACTIONS
  end

  def index
    result = conversation_finder.perform
    @conversations = result[:conversations]
    @conversations_count = result[:count]
  end

  def meta
    result = conversation_finder.perform_meta_only
    @conversations_count = result[:count]
  end

  def search
    result = conversation_finder.perform
    @conversations = result[:conversations]
    @conversations_count = result[:count]
  end

  def filter
    result = ::Conversations::FilterService.new(params.permit!, current_user, current_account).perform
    @conversations = result[:conversations]
    @conversations_count = result[:count]
  rescue CustomExceptions::CustomFilter::InvalidAttribute,
         CustomExceptions::CustomFilter::InvalidOperator,
         CustomExceptions::CustomFilter::InvalidQueryOperator,
         CustomExceptions::CustomFilter::InvalidValue => e
    render_could_not_create_error(e.message)
  end

  private

  def conversation_finder
    @conversation_finder ||= ConversationFinder.new(Current.user, params)
  end

  def validate_whatsapp_scope
    return unless params.key?(:whatsapp_scope)
    return if Ryze::GroupConversations::SCOPES.include?(params[:whatsapp_scope])

    render_could_not_create_error('Invalid whatsapp_scope')
  end
end
