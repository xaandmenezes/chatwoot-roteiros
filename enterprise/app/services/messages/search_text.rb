# The same message fields indexed for advanced search, evaluated on an authorized database relation.
class Messages::SearchText
  def initialize(account, text)
    @account = account
    @pattern = "%#{ActiveRecord::Base.sanitize_sql_like(text)}%"
  end

  def predicate
    messages = Message.arel_table
    messages[:content].matches(@pattern).or(email_subject.matches(@pattern)).or(messages[:id].in(transcribed_messages.arel))
  end

  private

  def email_subject
    email = json_field(Message.content_attributes_json, '->', 'email')
    json_field(email, '->>', 'subject')
  end

  def transcribed_messages
    transcription = json_field(Attachment.arel_table[:meta], '->>', 'transcribed_text')
    Attachment.where(account_id: @account.id).audio.where(transcription.matches(@pattern)).select(:message_id)
  end

  def json_field(column, operator, name)
    Arel::Nodes::InfixOperation.new(operator, column, Arel::Nodes.build_quoted(name))
  end
end
