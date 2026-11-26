class MessageRevocation < ApplicationRecord
  belongs_to :message, inverse_of: :customer_revocation

  validates :message_id, uniqueness: true
end
