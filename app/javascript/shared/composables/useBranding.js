/**
 * Composable for branding-related utilities
 * Provides methods to customize text with installation-specific branding
 */
import { useMapGetter } from 'dashboard/composables/store.js';

export function useBranding(branding = useMapGetter('globalConfig/get')) {
  /**
   * Replaces "Chatwoot" (any casing) in text with the installation name from
   * global config
   * @param {string} text - The text to process
   * @returns {string} - Text with "Chatwoot" replaced by installation name
   */
  const replaceInstallationName = text => {
    if (!text) return text;

    const installationName = branding.value?.installationName;
    if (!installationName) return text;

    return text.replace(/chatwoot/gi, installationName);
  };

  return {
    replaceInstallationName,
  };
}
