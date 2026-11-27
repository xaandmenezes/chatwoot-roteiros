class AddSupervisionToInboxMembers < ActiveRecord::Migration[8.1]
  def change
    add_column :inbox_members, :supervisor, :boolean, default: false, null: false
  end
end
