class Public::Api::V1::Inboxes::ContactsController < Public::Api::V1::InboxesController
  before_action :contact_inbox, except: [:create]
  before_action :process_hmac

  def show; end

  def create
    attributes = permitted_params.except(:identifier_hash)
    unless Conversations::AssignmentAccess.enabled?(@inbox_channel.inbox)
      @contact_inbox = build_contact_inbox(attributes)
      return
    end

    create_verified_contact_inbox(attributes)
  end

  def update
    contact_identify_action = ContactIdentifyAction.new(
      contact: @contact_inbox.contact,
      params: permitted_params.to_h.deep_symbolize_keys.except(:identifier)
    )
    contact_identify_action.perform
    @contact_inbox.reload
  end

  private

  def create_verified_contact_inbox(attributes)
    avatar_url = attributes.delete(:avatar_url)
    @contact_inbox = ContactInbox.transaction(requires_new: true) do
      binding = build_contact_inbox(attributes)
      raise ActiveRecord::Rollback unless binding.contact.identifier == attributes[:identifier]

      newly_created = binding.previously_new_record?
      binding.update!(hmac_verified: true)
      enqueue_avatar(binding.contact, avatar_url) if newly_created
      binding
    end
    render_unauthorized('HMAC failed: Invalid Identifier Hash Provided') unless @contact_inbox
  end

  def build_contact_inbox(attributes)
    ::ContactInboxWithContactBuilder.new(
      source_id: params[:source_id] || SecureRandom.uuid,
      inbox: @inbox_channel.inbox,
      contact_attributes: attributes
    ).perform
  end

  def enqueue_avatar(contact, avatar_url)
    Avatar::AvatarFromUrlJob.perform_later(contact, avatar_url) if avatar_url.present? && !contact.avatar.attached?
  end

  def contact_inbox
    @contact_inbox = @inbox_channel.inbox.contact_inboxes.find_by!(source_id: params[:id])
  end

  def process_hmac
    return if params[:identifier_hash].blank? && !requires_contact_hmac?
    return render_unauthorized('HMAC failed: Invalid Identifier Hash Provided') unless valid_hmac?

    @contact_inbox.update(hmac_verified: true) if @contact_inbox.present?
  end

  def valid_hmac?
    expected_identifier = hmac_identifier
    return false if expected_identifier.blank?
    return false unless params[:identifier].to_s == expected_identifier

    expected_hash = OpenSSL::HMAC.hexdigest(
      'sha256',
      @inbox_channel.hmac_token,
      expected_identifier
    )
    identifier_hash = params[:identifier_hash].to_s
    return false unless identifier_hash.bytesize == expected_hash.bytesize

    ActiveSupport::SecurityUtils.secure_compare(identifier_hash, expected_hash)
  end

  def hmac_identifier
    return params[:identifier].to_s if @contact_inbox.blank?

    @contact_inbox.contact.identifier.to_s
  end

  def permitted_params
    params.permit(:identifier, :identifier_hash, :email, :name, :avatar_url, :phone_number, custom_attributes: {})
  end
end
