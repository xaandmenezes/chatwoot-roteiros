class AddVisibilityToCustomFilters < ActiveRecord::Migration[8.0]
  def change
    add_column :custom_filters, :visibility, :string, default: 'personal', null: false
    change_column_null :custom_filters, :user_id, true
  end
end
