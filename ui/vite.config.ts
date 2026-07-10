import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vitejs.dev/config/
export default defineConfig({
    plugins: [react()],
    build: {
        // No manualChunks (r23 + vite 8): the old object-form pins are unsupported by rolldown,
        // and pinning react-syntax-highlighter had silently merged its ASYNC grammar payload into
        // a statically-preloaded chunk (619 kB on the startup path). Default splitting keeps the
        // PrismAsync bundle lazy (loads at the first rendered code block) — verify with
        // `grep modulepreload dist/index.html` after changing chunking.
        // Target older browsers for Chromebook / old laptop compatibility
        target: 'es2020',
        // Reduce chunk size warnings threshold
        chunkSizeWarningLimit: 600,
    },
    server: {
        port: 5173,
        proxy: {
            '/api': {
                target: 'http://localhost:3000',
                changeOrigin: true
            },
            '/ws': {
                target: 'ws://localhost:3000',
                ws: true,
                configure: (proxy, _options) => {
                    proxy.on('error', (err: any, _req, _res) => {
                        if (err.code !== 'ECONNRESET' && err.code !== 'EPIPE') {
                            console.log('WebSocket proxy error:', err);
                        }
                    });
                }
            },
            '/health': {
                target: 'http://localhost:3000',
                changeOrigin: true
            }
        }
    }
})
