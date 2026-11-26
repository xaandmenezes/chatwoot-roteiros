require 'rails_helper'

RSpec.describe V2::Reports::OutgoingMessagesCountBuilder do
  it 'rejects unsupported dimensions before reading account data' do
    builder = described_class.new(nil, { group_by: 'region' })

    expect { builder.build }.to raise_error(ArgumentError, 'Unsupported report dimension')
  end
end
