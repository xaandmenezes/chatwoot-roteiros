require 'rails_helper'

RSpec.describe Viari::ContactBinding do
  let(:contact) { create(:contact) }
  let(:binding) { described_class.new(contact, 'tenant-a') }

  it 'reuses a durable claim on timeout and rejects a competing payload' do
    first = SecureRandom.uuid
    expect(binding.claim_creation({ nome: 'Cliente' }, first)).to eq(first)
    expect(binding.claim_creation({ nome: 'Cliente' }, SecureRandom.uuid)).to eq(first)
    expect { binding.claim_creation({ nome: 'Outra pessoa' }, SecureRandom.uuid) }.to raise_error(described_class::Conflict)
    customer = SecureRandom.uuid
    binding.bind(customer, creation_key: first)
    contact.update!(additional_attributes: { 'viari_customer_binding' => 'not trusted' })
    expect(binding.customer_id).to eq(customer)
    expect(described_class.new(contact, 'tenant-b').customer_id).to be_nil
  end
end
