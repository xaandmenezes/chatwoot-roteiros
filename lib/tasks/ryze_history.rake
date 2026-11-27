namespace :ryze do
  desc 'Bind a conversation to an independently verified JID in the configured direct inbox'
  task :bind_history, [:account_id, :display_id, :jid] => :environment do |_task, args|
    conversation = Account.find(args.fetch(:account_id)).conversations.find_by!(display_id: Integer(args.fetch(:display_id), 10))
    Ryze::HistoryBinding.bind!(conversation, args.fetch(:jid))
    puts "Verified history binding for account #{conversation.account_id}, conversation #{conversation.display_id}."
  end
end
