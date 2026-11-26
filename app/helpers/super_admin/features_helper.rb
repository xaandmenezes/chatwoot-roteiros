module SuperAdmin::FeaturesHelper
  def self.available_features
    YAML.load(ERB.new(Rails.root.join('app/helpers/super_admin/features.yml').read).result).with_indifferent_access
  end

  def self.plan_details
    plan = ChatwootHub.pricing_plan

    if plan == 'premium'
      ActionController::Base.helpers.translate('super_admin.settings.premium_plan_details_html',
                                               plan: plan.titleize, quantity: ChatwootHub.pricing_plan_quantity)
    else
      ActionController::Base.helpers.translate('super_admin.settings.edition_plan_details_html', plan: plan.titleize)
    end
  end
end
