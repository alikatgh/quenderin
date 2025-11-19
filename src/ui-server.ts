import express from 'express';
import cors from 'cors';
import multer from 'multer';
import path from 'path';
import { fileURLToPath } from 'url';
import { loadConfig, saveConfig, QuenderinConfig } from './config.js';
import { testConnection } from './unified-generator.js';
import fs from 'fs/promises';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const upload = multer({ storage: multer.memoryStorage() });

export async function startUIServer(port = 3777) {
  const app = express();

  app.use(cors());
  app.use(express.json());
  app.use(express.static(path.join(__dirname, '../ui')));

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

      const configData = JSON.parse(req.file.buffer.toString('utf-8'));
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
        const data: any = await response.json();
        const models = data.models || [];
        res.json({
          success: true,
          available: true,
          models: models.map((m: any) => m.name)
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
