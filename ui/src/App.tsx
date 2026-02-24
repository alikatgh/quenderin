import { useState, useEffect } from 'react';
import { Menu, PanelRightClose, PanelRightOpen, TerminalSquare, AlertCircle, ArrowRight, Save, Mic } from 'lucide-react';
import { useAgentSocket } from './hooks/useAgentSocket.js';
import { ThemeProvider } from './context/ThemeContext.js';
import { Sidebar } from './components/Sidebar.js';
import { ChatArea } from './components/ChatArea.js';
import { GeneralChatArea } from './components/GeneralChatArea.js';
import { Inspector } from './components/Inspector.js';
import { TroubleshooterGuide } from './components/TroubleshooterGuide.js';
import { Docs } from './components/Docs.js';
import { Metrics } from './components/Metrics.js';

function WelcomeWizard({ onDismiss }: { onDismiss: () => void }) {
  const [step, setStep] = useState(1);
  const [picovoiceKey, setPicovoiceKey] = useState('');
  const [isSaving, setIsSaving] = useState(false);

  const handleFinish = async () => {
    setIsSaving(true);
    try {
      if (picovoiceKey.trim()) {
        await fetch('http://localhost:3000/api/config/voice', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ key: picovoiceKey.trim() })
        });
      }
    } catch (e) {
      console.error("Failed to save key", e);
    }
    onDismiss();
  };

  return (
    <div className="fixed inset-0 z-[100] flex items-center justify-center bg-black/40 backdrop-blur-sm p-4">
      <div className="w-full max-w-md bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-2xl shadow-2xl overflow-hidden animate-in fade-in zoom-in-95 duration-300">

        {/* Header Progress Bar */}
        <div className="w-full h-1 bg-zinc-100 dark:bg-zinc-800">
          <div className="h-full bg-purple-500 transition-all duration-300" style={{ width: `${(step / 3) * 100}%` }} />
        </div>

        <div className="p-6">
          {step === 1 && (
            <div className="animate-in slide-in-from-right-4 fade-in duration-300">
              <div className="w-12 h-12 bg-purple-100 dark:bg-purple-500/10 text-purple-600 dark:text-purple-400 rounded-xl flex items-center justify-center mb-5 border border-purple-200 dark:border-purple-500/20 shadow-sm">
                <TerminalSquare className="w-6 h-6" />
              </div>
              <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">The Quenderin Paradox</h2>
              <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-6">
                Welcome! Quenderin is an autonomous spatial agent that runs <strong>100% locally and offline</strong>. It watches physical pixels, parses node hierarchies, and uses inference to drive endpoints without traditional scripts.
              </p>
              <button onClick={() => setStep(2)} className="w-full bg-zinc-900 hover:bg-zinc-800 dark:bg-zinc-100 dark:hover:bg-white text-white dark:text-zinc-900 font-semibold py-2.5 px-4 rounded-xl transition-colors flex items-center justify-center gap-2 group">
                Next: Setup Brain <ArrowRight className="w-4 h-4 group-hover:translate-x-1 transition-transform" />
              </button>
            </div>
          )}

          {step === 2 && (
            <div className="animate-in slide-in-from-right-4 fade-in duration-300">
              <div className="w-12 h-12 bg-orange-100 dark:bg-orange-500/10 text-orange-600 dark:text-orange-400 rounded-xl flex items-center justify-center mb-5 border border-orange-200 dark:border-orange-500/20 shadow-sm">
                <AlertCircle className="w-6 h-6" />
              </div>
              <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">Install Neural Weights</h2>
              <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-6">
                Download your `.gguf` target model. To prevent absolute path errors, place it exactly inside the agent's safe environment block:
              </p>
              <div className="bg-zinc-100 dark:bg-zinc-800 p-3 rounded-xl mb-6 flex flex-col gap-1 border border-zinc-200 dark:border-zinc-700/50">
                <code className="text-xs text-orange-600 dark:text-orange-400 font-mono break-all font-semibold">wget https://.../llama-3-instruct-8b.Q4_K_M.gguf</code>
                <code className="text-xs text-zinc-700 dark:text-zinc-300 font-mono break-all font-semibold pb-1">mv llama-3-instruct-8b.Q4_K_M.gguf ~/.quenderin/models/</code>
              </div>
              <button onClick={() => setStep(3)} className="w-full bg-zinc-900 hover:bg-zinc-800 dark:bg-zinc-100 dark:hover:bg-white text-white dark:text-zinc-900 font-semibold py-2.5 px-4 rounded-xl transition-colors flex items-center justify-center gap-2 group">
                Next: Enable Voice <ArrowRight className="w-4 h-4 group-hover:translate-x-1 transition-transform" />
              </button>
            </div>
          )}

          {step === 3 && (
            <div className="animate-in slide-in-from-right-4 fade-in duration-300">
              <div className="w-12 h-12 bg-blue-100 dark:bg-blue-500/10 text-blue-600 dark:text-blue-400 rounded-xl flex items-center justify-center mb-5 border border-blue-200 dark:border-blue-500/20 shadow-sm">
                <Mic className="w-6 h-6" />
              </div>
              <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">Voice Control Engine</h2>
              <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-4">
                To enable offline wake-word and streaming recording, paste your free <strong>Picovoice Access Key</strong> below. This will be encrypted into your local config block.
              </p>
              <input
                type="text"
                placeholder="Paste Access Key..."
                value={picovoiceKey}
                onChange={(e) => setPicovoiceKey(e.target.value)}
                className="w-full bg-zinc-50 dark:bg-zinc-800 border-zinc-300 dark:border-zinc-700 text-zinc-900 dark:text-white rounded-xl px-4 py-3 text-[13px] font-mono focus:outline-none focus:ring-2 focus:ring-blue-500/50 mb-7 shadow-sm transition-all"
              />
              <button onClick={handleFinish} disabled={isSaving} className="w-full bg-blue-600 hover:bg-blue-700 text-white font-semibold py-2.5 px-4 rounded-xl transition-colors flex items-center justify-center gap-2 disabled:opacity-50">
                {isSaving ? "Saving Config..." : <>Finish Setup <Save className="w-4 h-4" /></>}
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

function AppContent() {
  const [goal, setGoal] = useState('');
  const [chatInput, setChatInput] = useState('');
  const [isSidebarOpen, setIsSidebarOpen] = useState(true);
  const [isInspectorOpen, setIsInspectorOpen] = useState(false);
  const [currentView, setCurrentView] = useState<'chat' | 'docs' | 'general_chat' | 'metrics'>('general_chat');
  const [activeModel, setActiveModel] = useState<string>('Loading Model...');
  const [showOnboarding, setShowOnboarding] = useState(false);

  useEffect(() => {
    // Check initial launch flag
    if (!localStorage.getItem('quenderin_setup_complete')) {
      setShowOnboarding(true);
    }

    const fetchHealth = async () => {
      try {
        // Fallback to exactly port 3000 mapped across the local Node backend
        const res = await fetch('http://localhost:3000/health');
        if (res.ok) {
          const data = await res.json();
          if (data.activeModel) setActiveModel(data.activeModel);
        }
      } catch (e) {
        // Silent block for dev environment cross-origin resets
      }
    };
    fetchHealth();
  }, []);

  const { wsReady, logs, status, currentUI, requiredAction, downloadProgress, sendGoal, sendChatMessage, resetSession, clearRequiredAction } = useAgentSocket();

  const handleStartAgent = (g: string) => {
    const sent = sendGoal(g);
    if (sent) {
      setCurrentView('chat');
      setGoal('');
    }
  };

  const handleSendChat = (m: string) => {
    const sent = sendChatMessage(m);
    if (sent) {
      setChatInput('');
    }
  };

  const handleNewGoal = () => {
    resetSession();
    setIsInspectorOpen(false);
    setCurrentView('chat');
  };

  // Auto-open inspector when we get UI data
  if (currentUI.length > 0 && !isInspectorOpen && status === 'running') {
    setIsInspectorOpen(true);
  }

  const dismissOnboarding = () => {
    localStorage.setItem('quenderin_setup_complete', 'true');
    setShowOnboarding(false);
  };

  return (
    <>
      {showOnboarding && <WelcomeWizard onDismiss={dismissOnboarding} />}
      {requiredAction && <TroubleshooterGuide action={requiredAction} onResolved={clearRequiredAction} downloadProgress={downloadProgress} />}

      <div className={`flex h-screen w-full bg-white dark:bg-[#18181b] overflow-hidden selection:bg-purple-500/30 font-sans text-zinc-900 dark:text-zinc-200 transition-all duration-500 ${showOnboarding || !!requiredAction ? 'blur-md pointer-events-none opacity-50 scale-[0.98]' : ''}`}>

        {/* Mobile Scrims */}
        {isSidebarOpen && (
          <div
            className="fixed inset-0 bg-black/50 z-30 xl:hidden backdrop-blur-sm transition-opacity"
            onClick={() => setIsSidebarOpen(false)}
          />
        )}
        {isInspectorOpen && (
          <div
            className="fixed inset-0 bg-black/50 z-30 md:hidden backdrop-blur-sm transition-opacity"
            onClick={() => setIsInspectorOpen(false)}
          />
        )}

        <Sidebar
          isOpen={isSidebarOpen}
          wsReady={wsReady}
          logs={logs}
          currentView={currentView}
          setCurrentView={(v) => {
            setCurrentView(v);
            if (window.innerWidth < 1280) setIsSidebarOpen(false);
          }}
          onNewGoal={() => {
            handleNewGoal();
            if (window.innerWidth < 1280) setIsSidebarOpen(false);
          }}
          activeModel={activeModel}
        />

        <div className="flex-1 flex flex-col relative h-full min-w-0 bg-white dark:bg-[#18181b] transition-colors duration-300">

          {/* Top Header Navigation */}
          <header className="h-[52px] flex items-center justify-between px-4 sticky top-0 bg-white/90 dark:bg-[#18181b]/90 backdrop-blur-md z-20 border-b border-zinc-200 dark:border-[#27272a] transition-colors duration-300">
            <div className="flex items-center gap-2">
              <button
                onClick={() => setIsSidebarOpen(!isSidebarOpen)}
                className="p-1.5 -ml-1.5 text-zinc-500 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 hover:bg-zinc-100 dark:hover:bg-[#27272a] rounded-md transition-colors"
              >
                <Menu className="w-5 h-5" />
              </button>
              <span className="font-semibold text-zinc-800 dark:text-zinc-200 text-[15px] pl-1 tracking-tight">Quenderin Agent</span>
            </div>

            <button
              onClick={() => setIsInspectorOpen(!isInspectorOpen)}
              className={`flex items-center gap-2 px-3 py-1.5 text-[13px] font-medium rounded-lg transition-colors border ${isInspectorOpen ? 'bg-zinc-100 dark:bg-[#27272a] border-zinc-300 dark:border-[#3f3f46] text-zinc-900 dark:text-white' : 'border-transparent text-zinc-500 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 hover:bg-zinc-100 dark:hover:bg-[#27272a]'}`}
            >
              {isInspectorOpen ? <PanelRightClose className="w-4 h-4" /> : <PanelRightOpen className="w-4 h-4" />}
              <span>Device Inspector</span>
              {currentUI.length > 0 && <span className="flex w-1.5 h-1.5 rounded-full bg-blue-500 shadow-[0_0_6px_rgba(59,130,246,0.3)] dark:shadow-[0_0_6px_rgba(59,130,246,0.8)] ml-1"></span>}
            </button>
          </header>

          {currentView === 'docs' ? (
            <Docs onBack={() => setCurrentView('general_chat')} />
          ) : currentView === 'metrics' ? (
            <Metrics onBack={() => setCurrentView('general_chat')} />
          ) : currentView === 'general_chat' ? (
            <GeneralChatArea
              logs={logs}
              status={status}
              chatInput={chatInput}
              setChatInput={setChatInput}
              onSend={handleSendChat}
            />
          ) : (
            <ChatArea
              logs={logs}
              status={status}
              goal={goal}
              setGoal={setGoal}
              onStart={handleStartAgent}
              setCurrentView={setCurrentView}
            />
          )}
        </div>

        <Inspector
          isOpen={isInspectorOpen}
          currentUI={currentUI}
          logs={logs}
        />

      </div>
    </>
  );
}

export default function App() {
  return (
    <ThemeProvider>
      <AppContent />
    </ThemeProvider>
  );
}
