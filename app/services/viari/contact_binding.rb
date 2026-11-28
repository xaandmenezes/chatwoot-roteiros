class Viari::ContactBinding
  class Conflict < StandardError; end

  def initialize(contact, integration_scope)
    @scope = { contact_id: contact.id, integration_scope: integration_scope }
  end

  def customer_id
    Viari::ContactLink.find_by(@scope)&.customer_id
  end

  def claim_creation(attributes, key)
    digest = OpenSSL::HMAC.hexdigest('SHA256', Rails.application.key_generator.generate_key('viari customer intention'), attributes.sort.to_json)
    record = Viari::ContactLink.create_or_find_by!(@scope)
    record.with_lock do
      raise Conflict if record.customer_id.present? || (record.creation_digest.present? && record.creation_digest != digest)
      record.update!(creation_key: key, creation_digest: digest) if record.creation_key.blank?
      record.creation_key
    end
  end

  def release_creation(key)
    Viari::ContactLink.where(@scope.merge(creation_key: key, customer_id: nil)).update_all(creation_key: nil, creation_digest: nil)
  end

  def bind(id, creation_key: nil)
    record = Viari::ContactLink.create_or_find_by!(@scope)
    record.with_lock do
      raise Conflict if (record.customer_id.present? && record.customer_id != id) || record.creation_key != creation_key
      record.update!(customer_id: id, creation_key: nil, creation_digest: nil)
    end
  end
end
