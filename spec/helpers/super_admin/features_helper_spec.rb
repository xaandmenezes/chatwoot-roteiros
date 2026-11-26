require 'rails_helper'

RSpec.describe SuperAdmin::FeaturesHelper do
  describe '.plan_details' do
    it 'escapes the plan name and retains its emphasis' do
      allow(ChatwootHub).to receive(:pricing_plan).and_return('research & development')
      allow(ChatwootHub).to receive(:pricing_plan_quantity).and_return(3)

      details = described_class.plan_details
      expect(details).to be_html_safe
      expect(details).to include('Research &amp; Development')
      expect(Nokogiri::HTML.fragment(details).css('span').map(&:text)).to eq(['Research & Development'])
    end

    it 'escapes the premium seat count and retains the plan and seat labels' do
      allow(ChatwootHub).to receive(:pricing_plan).and_return('premium')
      allow(ChatwootHub).to receive(:pricing_plan_quantity).and_return('5 & 6')

      details = described_class.plan_details
      expect(details).to include('5 &amp; 6 agents')
      expect(Nokogiri::HTML.fragment(details).css('span').map(&:text)).to eq(['Premium', '5 & 6 agents'])
    end
  end
end
