import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vitejs.dev/config/
export default defineConfig({
    plugins: [react()],
    build: {
        // Optimize chunk splitting for low-bandwidth / slow-CPU devices
        rollupOptions: {
            output: {
                manualChunks: {
                    // Split heavy deps into separate cacheable chunks.
                    // NOTE deliberately NO 'syntax' entry (r23): pinning react-syntax-highlighter
                    // to a named chunk merged its ASYNC-imported grammar bundle into a chunk the
                    // entry statically needs → 619 kB on the startup modulepreload path. Without
                    // the pin, Rollup keeps the PrismAsync payload in its own lazy chunk that only
                    // loads when the first code block renders.
                    'react-vendor': ['react', 'react-dom'],
                    'markdown': ['react-markdown', 'remark-gfm'],
                    'icons': ['lucide-react'],
                },
            },
        },
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
