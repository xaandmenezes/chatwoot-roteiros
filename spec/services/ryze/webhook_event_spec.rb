require 'rails_helper'

RSpec.describe Ryze::WebhookEvent do
  def revoke(actor)
    described_class.new(ActionController::Parameters.new(
                          event: 'message.exchange',
                          data: {
                            direction: 'incoming', id: 'original', chat: { jid: 'test@lid' },
                            message: { type: 'message_revoke', revoke: { revokeType: actor } }
                          }
                        ))
  end

  it 'attributes only a sender revocation to the customer' do
    expect(revoke('sender_revoke')).to be_customer_revoked
    expect(revoke('admin_revoke')).not_to be_customer_revoked
    expect(revoke('admin_revoke')).to be_valid
  end

  it 'rejects a revoke with unknown provenance' do
    expect(revoke(nil)).not_to be_valid
    expect(revoke('unexpected')).not_to be_valid
  end
end
