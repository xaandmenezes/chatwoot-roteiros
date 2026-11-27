import { initFaviconSwitcher, showBadgeOnFavicon } from '../faviconHelper';

describe('dashboard favicon', () => {
  let visibilityListener;

  afterEach(() => {
    if (visibilityListener) {
      document.removeEventListener('visibilitychange', visibilityListener);
    }
    visibilityListener = undefined;
    document.head
      .querySelectorAll('[rel="icon"]')
      .forEach(icon => icon.remove());
    vi.restoreAllMocks();
  });

  it.each(['', '/brand-assets/psr'])(
    'uses the configured icons for %s',
    prefix => {
      const original = `${prefix}/favicon-32x32.png`;
      const badge = `${prefix}/favicon-badge-32x32.png`;
      const icon = document.createElement('link');
      icon.rel = 'icon';
      icon.href = original;
      icon.sizes = '32x32';
      icon.dataset.faviconDefault = original;
      icon.dataset.faviconBadge = badge;
      document.head.append(icon);

      const addEventListener = vi.spyOn(document, 'addEventListener');
      const visibility = vi
        .spyOn(document, 'visibilityState', 'get')
        .mockReturnValue('hidden');
      initFaviconSwitcher();
      [, visibilityListener] = addEventListener.mock.calls.at(-1);

      showBadgeOnFavicon();
      expect(icon.getAttribute('href')).toBe(badge);

      document.dispatchEvent(new Event('visibilitychange'));
      expect(icon.getAttribute('href')).toBe(badge);

      visibility.mockReturnValue('visible');
      document.dispatchEvent(new Event('visibilitychange'));
      expect(icon.getAttribute('href')).toBe(original);
    }
  );
});
