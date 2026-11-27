const FAVICON_SELECTOR = '[data-favicon-badge]';

export const showBadgeOnFavicon = () => {
  document.querySelectorAll(FAVICON_SELECTOR).forEach(favicon => {
    favicon.href = favicon.dataset.faviconBadge;
  });
};

export const initFaviconSwitcher = () => {
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      document.querySelectorAll(FAVICON_SELECTOR).forEach(favicon => {
        favicon.href = favicon.dataset.faviconDefault;
      });
    }
  });
};
