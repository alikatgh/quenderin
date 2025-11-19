import express from 'express';
import cors from 'cors';
import multer from 'multer';
import path from 'path';
import { fileURLToPath } from 'url';
import { loadConfig, saveConfig, QuenderinConfig } from './config.js';
import { testConnection } from './unified-generator.js';
import fs from 'fs/promises';
import { rateLimit } from 'express-rate-limit';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Security: Limit file upload size to 1MB
const upload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: 1024 * 1024, // 1MB max
    files: 1,
  },
});

// Security: Rate limiting for API endpoints
const apiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100, // Limit each IP to 100 requests per windowMs
  message: 'Too many requests from this IP, please try again later.',
});

// Validate configuration data
function validateConfig(config: unknown): config is QuenderinConfig {
  if (!config || typeof config !== 'object') {
    return false;
  }

  const cfg = config as Record<string, unknown>;

  // Validate provider if present
  if (cfg.provider !== undefined) {
    const validProviders = ['ollama', 'openai', 'auto', 'gguf'];
    if (typeof cfg.provider !== 'string' || !validProviders.includes(cfg.provider)) {
      return false;
    }
  }

  // Validate API key length if present
  if (cfg.apiKey !== undefined) {
    if (typeof cfg.apiKey !== 'string' || cfg.apiKey.length > 500) {
      return false;
    }
  }

  // Validate model name if present
  if (cfg.modelName !== undefined) {
    if (typeof cfg.modelName !== 'string' || cfg.modelName.length > 100) {
      return false;
    }
  }

  // Validate baseURL if present
  if (cfg.baseURL !== undefined) {
    if (typeof cfg.baseURL !== 'string' || cfg.baseURL.length > 500) {
      return false;
    }
  }

  // Validate numeric fields
  if (cfg.maxTokens !== undefined && (typeof cfg.maxTokens !== 'number' || cfg.maxTokens < 1 || cfg.maxTokens > 100000)) {
    return false;
  }

  if (cfg.temperature !== undefined && (typeof cfg.temperature !== 'number' || cfg.temperature < 0 || cfg.temperature > 2)) {
    return false;
  }

  if (cfg.threads !== undefined && (typeof cfg.threads !== 'number' || cfg.threads < 1 || cfg.threads > 64)) {
    return false;
  }

  return true;
}

export async function startUIServer(port = 3777) {
  const app = express();

  // Security: Restrict CORS to localhost only
  app.use(cors({
    origin: [`http://localhost:${port}`, 'http://127.0.0.1:${port}'],
    credentials: true,
  }));

  app.use(express.json({ limit: '1mb' }));
  app.use(express.static(path.join(__dirname, '../ui')));

  // Apply rate limiting to all API routes
  app.use('/api/', apiLimiter);

  // Get current configuration
  app.get('/api/config', async (req, res) => {
    try {
      const config = await loadConfig();
      // Hide API key for security, only show if it exists
      res.json({
        ...config,
        apiKey: config.apiKey ? '••••••••' : undefined,
        hasApiKey: !!config.apiKey
      });
    } catch (error) {
      res.json({});
    }
  });

  // Save configuration
  app.post('/api/config', async (req, res) => {
    try {
      // Validate configuration before saving
      if (!validateConfig(req.body)) {
        return res.status(400).json({
          success: false,
          message: 'Invalid configuration data',
        });
      }

      const config: QuenderinConfig = req.body;
      await saveConfig(config);
      res.json({ success: true, message: 'Configuration saved successfully!' });
    } catch (error) {
      res.status(500).json({
        success: false,
        message: error instanceof Error ? error.message : 'Failed to save configuration'
      });
    }
  });

  // Upload configuration file (drag and drop)
  app.post('/api/upload-config', upload.single('config'), async (req, res) => {
    try {
      if (!req.file) {
        return res.status(400).json({ success: false, message: 'No file uploaded' });
      }

      // Validate file is valid JSON
      let configData: unknown;
      try {
        configData = JSON.parse(req.file.buffer.toString('utf-8'));
      } catch {
        return res.status(400).json({
          success: false,
          message: 'Invalid JSON file',
        });
      }

      // Validate configuration structure
      if (!validateConfig(configData)) {
        return res.status(400).json({
          success: false,
          message: 'Invalid configuration structure',
        });
      }

      await saveConfig(configData);
      res.json({ success: true, message: 'Configuration file uploaded successfully!', config: configData });
    } catch (error) {
      res.status(500).json({
        success: false,
        message: error instanceof Error ? error.message : 'Failed to process configuration file'
      });
    }
  });

  // Test connection
  app.post('/api/test-connection', async (req, res) => {
    try {
      const result = await testConnection();
      res.json({ success: true, message: 'Connection successful!', result });
    } catch (error) {
      res.status(500).json({
        success: false,
        message: error instanceof Error ? error.message : 'Connection failed'
      });
    }
  });

  // Auto-detect Ollama
  app.get('/api/detect-ollama', async (req, res) => {
    try {
      const response = await fetch('http://localhost:11434/api/tags');
      if (response.ok) {
        const data = (await response.json()) as { models?: Array<{ name: string }> };
        const models = data.models || [];
        res.json({
          success: true,
          available: true,
          models: models.map((m) => m.name)
        });
      } else {
        res.json({ success: true, available: false });
      }
    } catch (error) {
      res.json({ success: true, available: false });
    }
  });

  return new Promise<void>((resolve) => {
    app.listen(port, () => {
      console.log(`\n🎨 Quenderin UI is running!\n`);
      console.log(`   Open your browser to: http://localhost:${port}\n`);
      resolve();
    });
  });
}
