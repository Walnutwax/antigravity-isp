/**
 * Part 90: DOMContentLoaded Finalizer & IIFE Closure
 */
  function finishDomMount() {
    if (MODULES.theme !== false && typeof syncThemePreset === 'function') {
      syncThemePreset();
      if (window.__ag_theme_mode_observer && document.body) {
        try {
          window.__ag_theme_mode_observer.observe(document.body, {
            attributes: true,
            attributeFilter: ['class']
          });
        } catch (e) {}
      }
    } else {
      document.documentElement.removeAttribute('data-ag-preset');
      document.documentElement.removeAttribute('data-ag-theme-mode');
    }
    if (MODULES.i18n && document.body && typeof scanBodyFn === 'function') {
      scanBodyFn(document.body);
      if (window.__ag_i18n_observer && typeof I18N_OBS_OPTS !== 'undefined') {
        try {
          window.__ag_i18n_observer.observe(document.body, I18N_OBS_OPTS);
        } catch (e) {}
      }
    } else if (document.body) {
      restoreAllTranslations(document.body);
    }
    if (typeof checkRouteAndMountMetrics === 'function') {
      checkRouteAndMountMetrics();
    }
    ensureStylesAtEndOfHead();
  }

  if (!document.body) {
    window.__ag_dcl_handler = () => {
      window.__ag_body_ready = true;
      finishDomMount();
    };
    window.addEventListener('DOMContentLoaded', window.__ag_dcl_handler, { once: true });
  } else {
    window.__ag_body_ready = true;
    finishDomMount();
  }

  window.__ag_patch_version = PATCH_VERSION;
})(__AG_BOOT_PAYLOAD__);
