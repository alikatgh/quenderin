import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    // Only the backend's own tests. Without this, `vitest run` also walks vendored/symlinked
    // trees (e.g. android/jni/llama.cpp → the llama.cpp repo's own UI tests) and reports them
    // as failed suites. The ui/ workspace has its own toolchain.
    include: ['tests/**/*.{test,spec}.ts'],
    exclude: ['node_modules/**', 'dist/**', 'ui/**', 'apple/**', 'android/**'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      exclude: [
        'node_modules/',
        'dist/',
        '**/*.config.{js,ts}',
        '**/types.ts',
      ],
    },
  },
});
