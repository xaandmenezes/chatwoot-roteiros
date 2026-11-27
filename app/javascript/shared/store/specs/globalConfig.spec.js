import { createStore } from 'vuex';

describe('installation branding', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it.each([
    [
      'original stock name and PSR presentation',
      'Porto Seguro Roteiros',
      'Chatwoot',
      true,
    ],
    [
      'original custom name and PSR presentation',
      'Porto Seguro Roteiros',
      'Acme',
      false,
    ],
    ['original null name and stock presentation', 'Chatwoot', null, false],
    ['legacy stock name', 'Chatwoot', undefined, true],
    ['legacy custom name', 'Acme', undefined, false],
    ['legacy missing name', undefined, undefined, false],
  ])('%s', async (_, displayedName, installationName, isStockInstallation) => {
    const originalBranding =
      installationName === undefined
        ? {}
        : {
            INSTALLATION_BRANDING: {
              INSTALLATION_NAME: installationName,
              BRAND_NAME: 'Original brand',
              LOGO_THUMBNAIL: '/original-logo.png',
            },
          };
    vi.stubGlobal('globalConfig', {
      INSTALLATION_NAME: displayedName,
      BRAND_NAME: 'Displayed brand',
      LOGO_THUMBNAIL: '/displayed-logo.png',
      ...originalBranding,
    });
    const { default: globalConfig } = await import('../globalConfig');
    const { getters } = createStore({ modules: { globalConfig } });

    expect(getters['globalConfig/isAChatwootInstance']).toBe(
      isStockInstallation
    );
    expect(getters['globalConfig/isACustomBrandedInstance']).toBe(
      !isStockInstallation
    );
    expect(getters['globalConfig/get'].installationName).toBe(displayedName);
    expect(getters['globalConfig/installationBranding']).toEqual(
      installationName === undefined
        ? {
            installationName: displayedName,
            brandName: 'Displayed brand',
            logoThumbnail: '/displayed-logo.png',
          }
        : {
            installationName,
            brandName: 'Original brand',
            logoThumbnail: '/original-logo.png',
          }
    );
  });
});
