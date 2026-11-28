import { describe, expect, it, vi } from 'vitest';
import { webcrypto } from 'node:crypto';
import { runIntention } from '../intention';

describe('Viari operation identity', () => {
  it('recovers a timed-out operation across component lifetimes and isolates conversations', async () => {
    vi.stubGlobal('crypto', webcrypto);
    try {
      const scope = [1, 2, 3, 4];
      const payload = { grupoId: 'order', dados: { valor: 8 } };
      const keys = [];
      const timeout = async key => {
        keys.push(key);
        throw new Error('timeout');
      };
      const finish = async key => {
        keys.push(key);
        return true;
      };
      await expect(
        runIntention(scope, 'pagamento_registrar', payload, timeout)
      ).rejects.toThrow('timeout');
      await expect(
        runIntention(
          scope,
          'pagamento_registrar',
          { ...payload, dados: { valor: 9 } },
          finish
        )
      ).rejects.toMatchObject({ code: 'VIARI_PENDING' });
      await runIntention([1, 2, 5, 4], 'pagamento_registrar', payload, finish);
      await runIntention(scope, 'pagamento_registrar', payload, finish);
      await runIntention(scope, 'pagamento_registrar', payload, finish);
      expect(keys[0]).toBe(keys[2]);
      expect(keys[0]).not.toBe(keys[1]);
      expect(keys[0]).not.toBe(keys[3]);
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
