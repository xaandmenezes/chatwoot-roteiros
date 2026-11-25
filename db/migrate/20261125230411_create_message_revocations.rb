class CreateMessageRevocations < ActiveRecord::Migration[8.0]
  def change
    create_table :message_revocations do |t|
      t.references :message, type: :integer, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.text :content, null: false
      t.boolean :edited, null: false, default: false

      t.timestamps
    end
  end
end
