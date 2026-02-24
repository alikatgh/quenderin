import express, { Express } from 'express';
import cors from 'cors';
import path from 'path';
import { fileURLToPath } from 'url';
import healthRoute from './routes/health.js';
import { errorHandler } from './middlewares/errorHandler.js';
import { MetricsService } from './services/metrics.service.js';

export function createApp(metricsService?: MetricsService): Express {
    const app = express();

    // Global Middlewares
    app.use(cors());
    app.use(express.json());

    // Serve strictly static frontend relative to this file to support packaged ASARs
    const __filename = fileURLToPath(import.meta.url);
    const __dirname = path.dirname(__filename);
    const publicPath = path.join(__dirname, '..', '..', 'public');
    app.use(express.static(publicPath));

    // Routes
    app.use('/', healthRoute);

    if (metricsService) {
        app.get('/api/metrics', async (req, res) => {
            try {
                const metrics = await metricsService.getMetrics();
                res.json(metrics);
            } catch (err) {
                res.status(500).json({ error: 'Failed to fetch metrics' });
            }
        });
    }

    // Error Handling
    app.use(errorHandler);

    return app;
}
