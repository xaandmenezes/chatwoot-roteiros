class Viari::ContactLink < ApplicationRecord
  self.table_name = 'viari_contact_links'

  belongs_to :contact
  validates :integration_scope, presence: true
end
