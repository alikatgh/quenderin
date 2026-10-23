import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const root = fileURLToPath(new URL('.', import.meta.url));
const upstream = process.env.QUENDERIN_HOST_SOURCE;
if (!upstream?.startsWith('/')) throw new Error('Pinned patched Host source required');

export default {
  root,
  plugins: [{
    name: 'isolated-official-runtime-closure',
    enforce: 'pre',
    resolveId(source, importer) {
      // Resolve every official import against this complete lock, including
      // imports made by the upstream source. Never load its older pnpm peers.
      if (source.startsWith('@deepseek-ai/')) return { id: require.resolve(source), external: true };
      if (source === '@dsh-remote/protocol') return resolve(upstream, 'packages/protocol/src/index.ts');
      if (source === '@quenderin/patched-host-bridge') return resolve(upstream, 'packages/plugin/src/harness-remote-bridge.ts');
      if (source === '@quenderin/upstream-gateway-switch') return resolve(upstream, 'packages/plugin/src/typert-gateway-switch.ts');
      if (source === '@quenderin/host-policy') return resolve(upstream, 'packages/plugin/src/quenderin-host-policy.mjs');
      if (importer?.startsWith(upstream) && (source === 'zod' || source.startsWith('@xterm/'))) return { id: require.resolve(source), external: true };
    },
  }],
  test: {
    include: ['tests/official-runtime.test.ts'],
    testTimeout: 9500,
    hookTimeout: 9500,
    pool: 'forks',
    maxWorkers: 1,
    minWorkers: 1,
    isolate: true,
  },
};
