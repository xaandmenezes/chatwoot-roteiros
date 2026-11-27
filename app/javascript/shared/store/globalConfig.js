import { parseBoolean } from '@chatwoot/utils';
import { resolveMaximumFileUploadSize } from 'shared/helpers/FileHelper';

const {
  API_CHANNEL_NAME: apiChannelName,
  API_CHANNEL_THUMBNAIL: apiChannelThumbnail,
  APP_VERSION: appVersion,
  AZURE_APP_ID: azureAppId,
  BRAND_NAME: brandName,
  CAPTAIN_TOOLS_CATALOG_URL: captainToolsCatalogURL,
  CAPTAIN_TOOLS_MANIFEST_ENABLED: captainToolsManifestEnabled,
  CHATWOOT_INBOX_TOKEN: chatwootInboxToken,
  CREATE_NEW_ACCOUNT_FROM_DASHBOARD: createNewAccountFromDashboard,
  DIRECT_UPLOADS_ENABLED: directUploadsEnabled,
  DISPLAY_MANIFEST: displayManifest,
  GIT_SHA: gitSha,
  MAXIMUM_FILE_UPLOAD_SIZE: maximumFileUploadSize,
  HCAPTCHA_SITE_KEY: hCaptchaSiteKey,
  INSTALLATION_BRANDING: originalBranding,
  INSTALLATION_NAME: installationName,
  LOGO_THUMBNAIL: logoThumbnail,
  LOGO: logo,
  LOGO_DARK: logoDark,
  PRIVACY_URL: privacyURL,
  IS_ENTERPRISE: isEnterprise,
  IS_COMPANY_ENRICHMENT_ENABLED: isCompanyEnrichmentEnabled,
  TERMS_URL: termsURL,
  WIDGET_BRAND_URL: widgetBrandURL,
  DISABLE_USER_PROFILE_UPDATE: disableUserProfileUpdate,
  DISABLE_META_INBOX_CREATION: disableMetaInboxCreation,
  DISABLE_META_MESSAGE_SENDING: disableMetaMessageSending,
  DEPLOYMENT_ENV: deploymentEnv,
  ACTIVE_PLATFORM_BANNERS: activePlatformBanners,
  ACTIVE_FEATURE_ANNOUNCEMENTS: activeFeatureAnnouncements,
} = window.globalConfig || {};

const {
  INSTALLATION_NAME: originalInstallationName = installationName,
  BRAND_NAME: originalBrandName = brandName,
  LOGO_THUMBNAIL: originalLogoThumbnail = logoThumbnail,
} = originalBranding || {};

const state = {
  apiChannelName,
  apiChannelThumbnail,
  appVersion,
  azureAppId,
  brandName,
  captainToolsCatalogURL,
  captainToolsManifestEnabled: parseBoolean(captainToolsManifestEnabled),
  chatwootInboxToken,
  deploymentEnv,
  createNewAccountFromDashboard,
  directUploadsEnabled: parseBoolean(directUploadsEnabled),
  disableUserProfileUpdate: parseBoolean(disableUserProfileUpdate),
  disableMetaInboxCreation: parseBoolean(disableMetaInboxCreation),
  disableMetaMessageSending: parseBoolean(disableMetaMessageSending),
  displayManifest,
  gitSha,
  maximumFileUploadSize: resolveMaximumFileUploadSize(maximumFileUploadSize),
  hCaptchaSiteKey,
  installationName,
  installationBranding: {
    installationName: originalInstallationName,
    brandName: originalBrandName,
    logoThumbnail: originalLogoThumbnail,
  },
  logo,
  logoDark,
  logoThumbnail,
  privacyURL,
  termsURL,
  widgetBrandURL,
  isEnterprise: parseBoolean(isEnterprise),
  isCompanyEnrichmentEnabled: parseBoolean(isCompanyEnrichmentEnabled),
  activePlatformBanners: activePlatformBanners || [],
  activeFeatureAnnouncements: activeFeatureAnnouncements || [],
};

export const getters = {
  get: $state => $state,
  isOnChatwootCloud: $state => $state.deploymentEnv === 'cloud',
  isMetaInboxCreationDisabled: $state =>
    $state.deploymentEnv === 'cloud' && $state.disableMetaInboxCreation,
  isMetaMessageSendingDisabled: $state =>
    $state.deploymentEnv === 'cloud' && $state.disableMetaMessageSending,
  installationBranding: $state => $state.installationBranding,
  isAChatwootInstance: $state =>
    $state.installationBranding.installationName === 'Chatwoot',
  isACustomBrandedInstance: ($state, $getters) => !$getters.isAChatwootInstance,
};

export const actions = {};

export const mutations = {};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
