const financialActions = new Set([
  'pagamento_registrar',
  'pagamento_editar',
  'pagamento_estornar',
]);
const pendingKey = (scope, action) =>
  `chatwoot.viari.pending.${scope.join('.')}.${action}`;

export function acknowledgePending(scope, action) {
  const pending = pendingKey(scope, action);
  const digest = window.localStorage.getItem(pending);
  if (digest)
    window.localStorage.removeItem(`chatwoot.viari.intention.${digest}`);
  window.localStorage.removeItem(pending);
}

// Only fingerprints and UUIDs are stored. Request bodies can include personal
// information, so they stay in the form until the result has been reconciled.
export async function runIntention(scope, action, params, send) {
  const bytes = new TextEncoder().encode(
    JSON.stringify([scope, action, params])
  );
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  const digest = Array.from(hash, b => b.toString(16).padStart(2, '0')).join(
    ''
  );
  const storageKey = `chatwoot.viari.intention.${digest}`;
  const marker = pendingKey(scope, action);
  const tracked = financialActions.has(action);
  const pending = tracked && window.localStorage.getItem(marker);
  if (pending && pending !== digest)
    throw Object.assign(new Error('Unresolved financial operation'), {
      code: 'VIARI_PENDING',
      action,
    });
  const key = window.localStorage.getItem(storageKey) || crypto.randomUUID();
  window.localStorage.setItem(storageKey, key);
  if (tracked) window.localStorage.setItem(marker, digest);
  try {
    const result = await send(key);
    window.localStorage.removeItem(storageKey);
    if (tracked) window.localStorage.removeItem(marker);
    return result;
  } catch (error) {
    if ([400, 401, 403, 404, 422].includes(error.response?.status)) {
      window.localStorage.removeItem(storageKey);
      if (tracked) window.localStorage.removeItem(marker);
    }
    throw error;
  }
}
