// DOM Elements
const dropZone = document.getElementById('dropZone');
const fileInput = document.getElementById('fileInput');
const setupForm = document.getElementById('setupForm');
const providerSelect = document.getElementById('provider');
const messageDiv = document.getElementById('message');
const testBtn = document.getElementById('testBtn');
const ollamaDetected = document.getElementById('ollamaDetected');
const ollamaModels = document.getElementById('ollamaModels');

// Provider field groups
const openaiFields = document.getElementById('openaiFields');
const compatibleFields = document.getElementById('compatibleFields');
const ollamaFields = document.getElementById('ollamaFields');

// Initialize
document.addEventListener('DOMContentLoaded', () => {
    loadCurrentConfig();
    detectOllama();
    setupEventListeners();
});

// Event Listeners
function setupEventListeners() {
    // Drag and drop events
    dropZone.addEventListener('click', () => fileInput.click());
    dropZone.addEventListener('dragover', handleDragOver);
    dropZone.addEventListener('dragleave', handleDragLeave);
    dropZone.addEventListener('drop', handleDrop);
    fileInput.addEventListener('change', handleFileSelect);

    // Provider selection
    providerSelect.addEventListener('change', updateProviderFields);

    // Form submission
    setupForm.addEventListener('submit', handleFormSubmit);
    testBtn.addEventListener('click', testConnection);
}

// Drag and Drop Handlers
function handleDragOver(e) {
    e.preventDefault();
    e.stopPropagation();
    dropZone.classList.add('drag-over');
}

function handleDragLeave(e) {
    e.preventDefault();
    e.stopPropagation();
    dropZone.classList.remove('drag-over');
}

function handleDrop(e) {
    e.preventDefault();
    e.stopPropagation();
    dropZone.classList.remove('drag-over');

    const files = e.dataTransfer.files;
    if (files.length > 0) {
        handleFile(files[0]);
    }
}

function handleFileSelect(e) {
    const files = e.target.files;
    if (files.length > 0) {
        handleFile(files[0]);
    }
}

async function handleFile(file) {
    if (!file.name.endsWith('.json')) {
        showMessage('Please upload a JSON file', 'error');
        return;
    }

    const formData = new FormData();
    formData.append('config', file);

    try {
        const response = await fetch('/api/upload-config', {
            method: 'POST',
            body: formData
        });

        const result = await response.json();

        if (result.success) {
            showMessage(result.message, 'success');
            loadCurrentConfig();
        } else {
            showMessage(result.message, 'error');
        }
    } catch (error) {
        showMessage('Failed to upload configuration: ' + error.message, 'error');
    }
}

// Provider Fields Management
function updateProviderFields() {
    const provider = providerSelect.value;

    // Hide all provider fields
    openaiFields.classList.remove('active');
    compatibleFields.classList.remove('active');
    ollamaFields.classList.remove('active');

    // Show relevant fields
    if (provider === 'openai') {
        openaiFields.classList.add('active');
    } else if (provider === 'openai-compatible') {
        compatibleFields.classList.add('active');
    } else if (provider === 'ollama') {
        ollamaFields.classList.add('active');
    }
}

// Form Submission
async function handleFormSubmit(e) {
    e.preventDefault();

    const provider = providerSelect.value;
    const config = { provider };

    // Collect fields based on provider
    if (provider === 'openai') {
        config.apiKey = document.getElementById('apiKey').value;
        config.modelName = document.getElementById('modelName').value;
    } else if (provider === 'openai-compatible') {
        config.baseURL = document.getElementById('baseURL').value;
        config.apiKey = document.getElementById('apiKeyCompat').value;
        config.modelName = document.getElementById('modelNameCompat').value;
        config.provider = 'openai'; // Use OpenAI provider with custom URL
    } else if (provider === 'ollama') {
        config.modelName = document.getElementById('ollamaModel').value;
        const ollamaURL = document.getElementById('ollamaURL').value;
        if (ollamaURL) {
            config.baseURL = ollamaURL;
        }
    }

    try {
        const response = await fetch('/api/config', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(config)
        });

        const result = await response.json();

        if (result.success) {
            showMessage(result.message, 'success');
        } else {
            showMessage(result.message, 'error');
        }
    } catch (error) {
        showMessage('Failed to save configuration: ' + error.message, 'error');
    }
}

// Load Current Configuration
async function loadCurrentConfig() {
    try {
        const response = await fetch('/api/config');
        const config = await response.json();

        if (config.provider) {
            providerSelect.value = config.provider;
            updateProviderFields();

            // Populate fields
            if (config.provider === 'openai') {
                if (config.modelName) {
                    document.getElementById('modelName').value = config.modelName;
                }
            } else if (config.provider === 'ollama') {
                if (config.modelName) {
                    document.getElementById('ollamaModel').value = config.modelName;
                }
                if (config.baseURL) {
                    document.getElementById('ollamaURL').value = config.baseURL;
                }
            }
        }
    } catch (error) {
        console.error('Failed to load config:', error);
    }
}

// Test Connection
async function testConnection() {
    const originalText = testBtn.textContent;
    testBtn.textContent = 'Testing...';
    testBtn.disabled = true;

    try {
        const response = await fetch('/api/test-connection', {
            method: 'POST'
        });

        const result = await response.json();

        if (result.success) {
            showMessage('✓ Connection successful!', 'success');
        } else {
            showMessage('Connection failed: ' + result.message, 'error');
        }
    } catch (error) {
        showMessage('Connection test failed: ' + error.message, 'error');
    } finally {
        testBtn.textContent = originalText;
        testBtn.disabled = false;
    }
}

// Detect Ollama
async function detectOllama() {
    try {
        const response = await fetch('/api/detect-ollama');
        const result = await response.json();

        if (result.available && result.models && result.models.length > 0) {
            ollamaModels.textContent = result.models.join(', ');
            ollamaDetected.classList.remove('hidden');

            // Auto-select Ollama if detected and no config exists
            const configResponse = await fetch('/api/config');
            const config = await configResponse.json();

            if (!config.provider || config.provider === 'auto') {
                providerSelect.value = 'ollama';
                updateProviderFields();

                // Set first available model
                if (result.models.length > 0) {
                    document.getElementById('ollamaModel').value = result.models[0];
                }
            }
        }
    } catch (error) {
        console.error('Failed to detect Ollama:', error);
    }
}

// Show Message
function showMessage(text, type) {
    messageDiv.textContent = text;
    messageDiv.className = `message ${type} show`;

    setTimeout(() => {
        messageDiv.classList.remove('show');
    }, 5000);
}
