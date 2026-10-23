// Explicit config keeps a nested upstream checkout from discovering Quenderin's
// unrelated parent vitest.config.ts. No dependency install in the parent is needed.
export default {
  test: {
    include: ['tests/quenderin-host.integration.test.ts'],
    testTimeout: 5000,
    pool: 'threads',
    maxWorkers: 1,
    minWorkers: 1,
  },
};
