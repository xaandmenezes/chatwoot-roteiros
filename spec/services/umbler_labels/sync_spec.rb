require 'rails_helper'

describe UmblerLabels::Sync do
  subject(:sync) { described_class.new(account, client: client) }

  let(:account_id) { 934_533 }
  let(:account) { create(:account, id: account_id) }
  let(:phone) { '+5511987654321' }
  let(:legacy_phone) { '+551187654321' }
  let(:contact) { create(:contact, account: account, phone_number: phone) }
  let(:client) { instance_double(UmblerLabels::Client) }
  let(:source_tag) { { 'id' => 'source-tag', 'name' => 'Falta ORÇAMENTO' } }
  let(:catalog_tag) { source_tag.merge('color' => 'Blue', 'description' => nil) }
  let(:source_contact) { { 'id' => 'source-contact', 'phoneNumber' => legacy_phone, 'contactType' => 'DirectMessage', 'tags' => [source_tag] } }

  around do |example|
    with_modified_env UMBLER_LABELS_ACCOUNT_ID: account_id.to_s, UMBLER_ORGANIZATION_ID: 'test-org', UMBLER_API_TOKEN: 'test-token' do
      example.run
    end
  end

  before do
    allow(client).to receive(:label_catalog).and_return('source-tag' => catalog_tag)
    allow(client).to receive(:search_contacts).with(phone).and_return([])
    allow(client).to receive(:search_contacts).with(legacy_phone).and_return([source_contact])
  end

  it 'adds the matching source labels once while preserving the existing contact labels' do
    contact.update_labels(['manual'])
    existing_label = account.labels.create!(title: 'falta-orçamento', color: '#112233')
    conversation = create(:conversation, account: account, contact: contact, status: :resolved)

    expect { expect(sync.call(contact)).to eq(:updated) }.not_to change(Message, :count)
    expect(sync.call(contact)).to eq(:unchanged)
    expect(contact.reload.label_list).to contain_exactly('manual', 'falta-orçamento')
    expect(existing_label.reload.color).to eq('#112233')
    expect(conversation.reload).to be_resolved
    expect(conversation.label_list).to be_empty
  end

  it 'creates the catalog label for a newly discovered source label' do
    catalog_tag['color'] = 'Pink'
    catalog_tag['description'] = 'Fonte Umbler'

    expect(sync.call(contact)).to eq(:updated)
    expect(account.labels.find_by!(title: 'falta-orçamento')).to have_attributes(color: '#FF69B4', description: 'Fonte Umbler')
  end

  it 'skips a source label when multiple catalog IDs normalize to the same title' do
    other_tag = catalog_tag.merge('id' => 'other', 'name' => 'falta-orçamento')
    allow(client).to receive(:label_catalog).and_return('source-tag' => catalog_tag, 'other' => other_tag)
    contact.update_labels(['manual'])

    expect(sync.call(contact)).to eq(:ambiguous)
    expect(contact.reload.label_list).to contain_exactly('manual')
    expect(account.labels).to be_empty
  end

  it 'reports a known contact with an empty source label list' do
    source_contact['tags'] = []

    expect(sync.call(contact)).to eq(:no_labels)
  end

  it 'reports no match when neither variant exists in Umbler' do
    allow(client).to receive(:search_contacts).with(legacy_phone).and_return([])

    expect(sync.call(contact)).to eq(:unmatched)
  end

  it 'skips conflicting matches in Umbler' do
    allow(client).to receive(:search_contacts).with(phone).and_return([source_contact.merge('id' => 'other', 'phoneNumber' => phone)])

    expect(sync.call(contact)).to eq(:ambiguous)
    expect(contact.reload.label_list).to be_empty
    expect(account.labels).to be_empty
  end

  it 'skips two Umbler contacts with the same phone' do
    allow(client).to receive(:search_contacts).with(legacy_phone).and_return([source_contact, source_contact.merge('id' => 'other')])

    expect(sync.call(contact)).to eq(:ambiguous)
    expect(contact.reload.label_list).to be_empty
  end

  it 'skips a Brazilian variant shared by two existing contacts' do
    create(:contact, account: account, phone_number: legacy_phone)

    expect(sync.call(contact)).to eq(:ambiguous)
    expect(client).not_to have_received(:search_contacts)
  end

  it 'skips WhatsApp groups even when a phone is present' do
    contact.update!(identifier: '99999999999@g.us')

    expect(sync.call(contact)).to eq(:unmatched)
    expect(client).not_to have_received(:search_contacts)
  end

  it 'treats missing source labels as a service error so they are visible' do
    source_contact.delete('tags')

    expect { sync.call(contact) }.to raise_error(UmblerLabels::Client::Error)
    expect(contact.reload.label_list).to be_empty
  end

  it 'never synchronizes a different Chatwoot account' do
    another_contact = create(:contact, phone_number: phone)

    expect { sync.call(another_contact) }.to raise_error(UmblerLabels::Client::Error)
    expect(client).not_to have_received(:search_contacts)
  end
end
