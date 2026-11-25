class UmblerLabels::LabelWriter
  class AmbiguousLabel < UmblerLabels::Client::Error; end

  COLORS = {
    'Blue' => '#2563EB', 'Skyblue' => '#56B4E9', 'Cyan' => '#06B6D4', 'Aquamarine' => '#34D3AB',
    'Green' => '#008000', 'Kiwi' => '#8CBF26', 'Gold' => '#E8AE00', 'Amber' => '#FFBF00',
    'Tangerine' => '#F97316', 'Chocolate' => '#D2691E', 'Salmon' => '#FA8072', 'Tomato' => '#FF6347',
    'Rose' => '#F43F5E', 'Pink' => '#FF69B4', 'Magenta' => '#D946EF', 'Violet' => '#8B5CF6',
    'Grape' => '#8447B1', 'Gray' => '#808080', 'Silver' => '#C0C0C0', 'Umblerito' => '#4866DC'
  }.freeze

  def initialize(account, catalog)
    @account = account
    @catalog = catalog
    @catalog_by_title = catalog.values.group_by { |tag| normalized_title(tag['name']) }
  end

  def resolve(refs)
    refs.map { |ref| attributes_for(ref) }.uniq { |attributes| attributes.fetch(:title) }.sort_by { |attributes| attributes.fetch(:title) }
  end

  def apply(contact, attributes)
    attributes.each { |label| ensure_catalog_label(label) }
    tags = resolve_tags(attributes.pluck(:title))
    present_ids = contact.taggings.where(context: 'labels').pluck(:tag_id)
    new_tags = tags.reject { |tag| present_ids.include?(tag.id) }

    # Use the taggings directly to avoid contact callbacks and webhook dispatch during imports.
    new_tags.each { |tag| contact.taggings.create!(tag: tag, context: 'labels') }
    new_tags.empty? ? :unchanged : :updated
  end

  private

  def resolve_tags(titles)
    tags = ActsAsTaggableOn::Tag.find_or_create_all_with_like_by_name(titles)
    raise UmblerLabels::Client::Error, 'Could not persist Chatwoot tags' unless tags.all?(&:persisted?)

    tags.uniq(&:id)
  end

  def attributes_for(ref)
    tag = ref.is_a?(Hash) && @catalog[ref['id']]
    title = tag && normalized_title(tag['name'])
    raise UmblerLabels::Client::Error, 'Umbler contact references an unknown label' if title.blank?
    raise AmbiguousLabel, 'Distinct Umbler labels map to the same Chatwoot title' if @catalog_by_title.fetch(title).size > 1

    { title: title, color: COLORS[tag['color']], description: tag['description'] }.compact
  end

  def normalized_title(name)
    return unless name.is_a?(String)

    name.unicode_normalize(:nfc).strip.downcase.gsub(/[[:space:]]+/, '-')
  end

  def ensure_catalog_label(attributes)
    title = attributes.fetch(:title)
    @account.labels.find_or_create_by!(title: title) do |label|
      label.assign_attributes(attributes.except(:title))
    end
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record.errors.added?(:title, :taken, value: title)

    @account.labels.find_by!(title: title)
  end
end
