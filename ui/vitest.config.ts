import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';

// Component-level tests for the dashboard (r11: automated a11y via axe-core, plus behavior
// pins for the extracted settings sections). Kept separate from vite.config.ts so the dev
// server config stays test-free; run with `npm test` from ui/.
export default defineConfig({
    plugins: [react()],
    test: {
        environment: 'jsdom',
        include: ['src/**/*.test.tsx', 'tests/**/*.test.tsx'],
        globals: false,
    },
});
