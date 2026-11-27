class CreateRyzeReactionEchoes < ActiveRecord::Migration[8.1]
  def change
    create_table :ryze_reaction_echoes do |t|
      t.references :conversation, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :provider_key, null: false, limit: 64
      t.string :reaction_key, limit: 64
      t.timestamps
      t.index [:conversation_id, :provider_key], unique: true
    end
  end
end
