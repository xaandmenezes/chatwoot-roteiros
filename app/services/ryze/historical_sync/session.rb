class Ryze::HistoricalSync::Session
  attr_reader :chat_jid, :client, :deadline, :media

  def initialize(conversation, client: nil)
    @conversation = conversation
    @deadline = Ryze::HistoricalSync::RUN_BUDGET.from_now
    @chat_jid = Ryze::OutgoingEditEligibility.conversation_jid(conversation)
    verify_target!
    @client = client || default_client
    @media = Ryze::HistoricalSync::MediaAttacher.new(
      conversation: conversation, client: @client, deadline: deadline, locked_write: method(:with_current_target)
    )
  end

  def with_current_target
    @conversation.with_lock do
      verify_target!
      yield
    end
  end

  private

  def verify_target!
    return if Ryze::HistoricalSync.enabled?(@conversation) && chat_jid == Ryze::OutgoingEditEligibility.conversation_jid(@conversation)

    raise Ryze::HistoricalSync::NotEnabled, 'Ryze historical sync is not enabled for this conversation'
  end

  def default_client
    Ryze::Client.new(
      instance: ENV.fetch('RYZE_INSTANCE_NAME'), token: ENV.fetch('RYZE_EDIT_API_TOKEN'),
      read_timeout: 12, request_budget: Ryze::HistoricalSync::RUN_BUDGET.to_i,
      limits: Ryze::Client::ResponseLimits.new(deadline: deadline, max_bytes: Ryze::HistoricalSync::MediaAttacher::MAX_RESPONSE_BYTES)
    )
  end
end
