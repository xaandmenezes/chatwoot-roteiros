class UmblerLabels::Sync
  PHONE_NUMBER = /\A\+[1-9]\d{1,14}\z/

  def self.configured?(account)
    account.id.present? && ENV['UMBLER_LABELS_ACCOUNT_ID'].to_s.strip == account.id.to_s &&
      ENV['UMBLER_ORGANIZATION_ID'].to_s.strip.present? && ENV['UMBLER_API_TOKEN'].to_s.strip.present?
  end

  def initialize(account, client: nil)
    @account = account
    @client = client
  end

  def call(contact)
    assert_account!(contact)
    return :unmatched unless eligible?(contact)

    phones = phone_candidates(contact.phone_number)
    return :ambiguous if another_contact?(contact, phones)

    match = find_source_contact(phones)
    return :unmatched unless match

    sync_labels(contact, match, phones)
  rescue UmblerLabels::Client::AmbiguousSearch, UmblerLabels::LabelWriter::AmbiguousLabel
    :ambiguous
  end

  private

  def assert_account!(contact)
    return if self.class.configured?(@account) && contact.account_id == @account.id

    raise UmblerLabels::Client::Error, 'Umbler labels are unavailable for this account'
  end

  def find_source_contact(phones)
    matches = phones.flat_map { |phone| client.search_contacts(phone) }.uniq { |match| source_id(match) }
    raise UmblerLabels::Client::AmbiguousSearch, 'Multiple Umbler contact records match the phone number' if matches.size > 1

    match = matches.first
    match if match && match['contactType'] == 'DirectMessage'
  end

  def client
    @client ||= UmblerLabels::Client.new(
      organization_id: ENV.fetch('UMBLER_ORGANIZATION_ID').strip,
      token: ENV.fetch('UMBLER_API_TOKEN').strip
    )
  end

  def writer
    @writer ||= UmblerLabels::LabelWriter.new(@account, client.label_catalog)
  end

  def eligible?(contact)
    PHONE_NUMBER.match?(contact.phone_number.to_s) && !contact.identifier.to_s.end_with?('@g.us')
  end

  def phone_candidates(phone)
    Whatsapp::PhoneNormalizers::BrazilPhoneNormalizer.new.contact_candidates(phone.delete_prefix('+')).map { |digits| "+#{digits}" }
  end

  def another_contact?(contact, phones)
    @account.contacts.where(phone_number: phones).where.not(id: contact.id).exists?
  end

  def source_id(match)
    id = match['id']
    raise UmblerLabels::Client::Error, 'Umbler returned a contact without an identifier' unless id.is_a?(String) && id.present?

    id
  end

  def sync_labels(contact, source_contact, phones)
    refs = source_contact['tags']
    raise UmblerLabels::Client::Error, 'Umbler returned an invalid contact label list' unless refs.is_a?(Array)
    return :no_labels if refs.empty?

    labels = writer.resolve(refs)
    Contact.transaction do
      locked = @account.contacts.lock.find_by(id: contact.id)
      next :unmatched unless locked && eligible?(locked) && locked.phone_number == contact.phone_number
      next :ambiguous if another_contact?(locked, phones)

      writer.apply(locked, labels)
    end
  end
end
