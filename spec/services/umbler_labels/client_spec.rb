require 'rails_helper'

describe UmblerLabels::Client do
  subject(:client) { described_class.new(organization_id: 'test-org', token: 'test-token') }

  let(:phone) { '+5511987654321' }
  let(:url) { 'https://app-utalk.umbler.com/api/v1/contacts/' }
  let(:query) { { organizationId: 'test-org', QueryString: '5511987654321', Take: 25, Behavior: 'CountAllAndGetSlice' } }
  let(:headers) { { 'Authorization' => 'Bearer test-token' } }
  let(:contact) { { 'id' => 'source-contact', 'phoneNumber' => phone, 'contactType' => 'DirectMessage', 'tags' => [] } }

  it 'only returns records whose phone number exactly matches the search' do
    other_contact = contact.merge('phoneNumber' => '+5511987654322')
    stub_request(:get, url)
      .with(query: query, headers: headers)
      .to_return(body: { page: { totalItems: 2 }, items: [other_contact, contact] }.to_json)

    expect(client.search_contacts(phone)).to eq([contact])
  end

  it 'distinguishes an empty search result from a failed request' do
    stub_request(:get, url).with(query: query, headers: headers).to_return(body: { page: { totalItems: 0 }, items: [] }.to_json)

    expect(client.search_contacts(phone)).to be_empty
  end

  it 'refuses to make a match from an incomplete result' do
    stub_request(:get, url).with(query: query, headers: headers).to_return(body: { page: { totalItems: 26 }, items: [contact] }.to_json)

    expect { client.search_contacts(phone) }.to raise_error(described_class::AmbiguousSearch)
  end

  it 'rejects invalid credentials without including the response body in the error' do
    stub_request(:get, url).with(query: query, headers: headers).to_return(status: 401, body: 'private details test-token')

    expect { client.search_contacts(phone) }.to raise_error(described_class::Error, 'Umbler request failed (HTTP 401)')
  end

  it 'reports invalid JSON without including the body in the error' do
    stub_request(:get, url).with(query: query, headers: headers).to_return(body: '{private details test-token}')

    expect { client.search_contacts(phone) }.to raise_error(described_class::Error, 'Umbler returned invalid JSON')
  end

  it 'reports a timeout so the batch can be tried again' do
    stub_request(:get, url).with(query: query, headers: headers).to_timeout

    expect { client.search_contacts(phone) }.to raise_error(described_class::Error, 'Could not reach Umbler')
  end

  it 'reads the tag catalog once per client' do
    tag = { 'id' => 'source-id', 'name' => 'Origem', 'color' => 'Blue' }
    request = stub_request(:get, 'https://app-utalk.umbler.com/api/v1/tags/')
              .with(query: { organizationId: 'test-org', Skip: 0, Take: 250, Behavior: 'CountAllAndGetSlice' }, headers: headers)
              .to_return(body: { page: { totalItems: 1 }, items: [tag] }.to_json)

    expect(client.label_catalog).to eq('source-id' => tag)
    expect(client.label_catalog).to eq('source-id' => tag)
    expect(request).to have_been_requested.once
  end
end
