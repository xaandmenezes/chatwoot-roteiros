class CreateUmblerLabelSyncs < ActiveRecord::Migration[8.0]
  def change
    create_table :umbler_label_syncs do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.integer :status, null: false, default: 0
      t.bigint :last_contact_id, null: false, default: 0
      t.bigint :cursor, null: false, default: 0
      t.jsonb :counts, null: false, default: {}
      t.timestamps
    end
    add_index :umbler_label_syncs, [:account_id, :id]
  end
end
