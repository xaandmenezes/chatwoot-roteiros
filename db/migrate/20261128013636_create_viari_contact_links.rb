class CreateViariContactLinks < ActiveRecord::Migration[7.1]
  def change
    create_table :viari_contact_links do |t|
      t.references :contact, type: :integer, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :integration_scope, null: false
      t.uuid :customer_id
      t.uuid :creation_key
      t.string :creation_digest
      t.timestamps
      t.index [:contact_id, :integration_scope], unique: true
    end
  end
end
