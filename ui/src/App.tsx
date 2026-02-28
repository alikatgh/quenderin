import { useState, useEffect } from 'react';
import { Menu, PanelRightClose, PanelRightOpen, TerminalSquare, ArrowRight, Download, CheckCircle2, BrainCircuit, Mic } from 'lucide-react';
import { useAgentSocket } from './hooks/useAgentSocket.js';
import { ThemeProvider } from './context/ThemeContext.js';
import { Sidebar } from './components/Sidebar.js';
import { ChatArea } from './components/ChatArea.js';
import { GeneralChatArea } from './components/GeneralChatArea.js';
import { Inspector } from './components/Inspector.js';
import { TroubleshooterGuide } from './components/TroubleshooterGuide.js';
import { Docs } from './components/Docs.js';
import { Metrics } from './components/Metrics.js';
import { SettingsArea } from './components/SettingsArea.js';
import { useTheme } from './context/ThemeContext.js';
import { PrivacyLock } from './components/PrivacyLock.js';

function WelcomeWizard({ onDismiss, downloadProgress }: { onDismiss: () => void, downloadProgress: number }) {
  const [step, setStep] = useState(1);
  const [isFinishing, setIsFinishing] = useState(false);
  const [isModelDownloading, setIsModelDownloading] = useState(false);
  const [isVoiceDownloading, setIsVoiceDownloading] = useState(false);
  const [voiceDownloadProgress, setVoiceDownloadProgress] = useState(0);

  const handleDownloadModel = async () => {
    setIsModelDownloading(true);
    try {
      await fetch('/api/models/download', { method: 'POST' });
    } catch (e) {
      console.error("Failed to sequence download routing from Wizard", e);
      setIsModelDownloading(false);
    }
  };

  const handleDownloadVoice = async () => {
    setIsVoiceDownloading(true);
    try {
      // Simulate progress since unzipper progress is complex, the whole zip is just 50MB
      setVoiceDownloadProgress(10);
      const interval = setInterval(() => {
        setVoiceDownloadProgress(p => p >= 90 ? 90 : p + 10);
      }, 500);

      await fetch('/api/voice/download', { method: 'POST' });

      clearInterval(interval);
      setVoiceDownloadProgress(100);
      setTimeout(() => setIsVoiceDownloading(false), 1000);
    } catch (e) {
      console.error("Failed to sequence voice download", e);
      setIsVoiceDownloading(false);
      setVoiceDownloadProgress(0);
    }
  };

  const handleFinish = async () => {
    setIsFinishing(true);
    try {
      await new Promise(r => setTimeout(r, 500));
      onDismiss();
    } catch (e) {
      console.error("Failed to run finish", e);
    } finally {
      setIsFinishing(false);
    }
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
              <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">Welcome to Quenderin</h2>
              <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-6 font-medium">
                Welcome! Quenderin is a private assistant that runs **100% locally on your computer**. It helps you finish tasks by watching your phone screen and understanding how to use your apps, just like a human would.
              </p>
              <button onClick={() => setStep(2)} className="w-full bg-zinc-900 hover:bg-zinc-800 dark:bg-zinc-100 dark:hover:bg-white text-white dark:text-zinc-900 font-semibold py-2.5 px-4 rounded-xl transition-colors flex items-center justify-center gap-2 group">
                Next: Setup AI Knowledge <ArrowRight className="w-4 h-4 group-hover:translate-x-1 transition-transform" />
              </button>
            </div>
          )}

          {step === 2 && (
            <div className="animate-in slide-in-from-right-4 fade-in duration-300">
              <div className="w-12 h-12 bg-emerald-100 dark:bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 rounded-xl flex items-center justify-center mb-5 border border-emerald-200 dark:border-emerald-500/20 shadow-sm">
                <BrainCircuit className="w-6 h-6" />
              </div>
              <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">Get AI Knowledge</h2>
              <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-6">
                Quenderin needs to download its "knowledge" to understand your screen and help you:
              </p>

              {downloadProgress === 100 ? (
                <div className="animate-in fade-in duration-300 mb-6">
                  <div className="bg-emerald-50 dark:bg-emerald-900/20 border border-emerald-200 dark:border-emerald-500/30 rounded-xl p-4 flex items-start gap-3">
                    <CheckCircle2 className="w-5 h-5 text-emerald-500 shrink-0 mt-0.5" />
                    <div>
                      <p className="text-sm font-semibold text-emerald-900 dark:text-emerald-300">Knowledge Installed Successfully</p>
                      <p className="text-xs text-emerald-700 dark:text-emerald-400 mt-1">The AI assistant is now saved to your computer.</p>
                    </div>
                  </div>
                </div>
              ) : isModelDownloading || downloadProgress > 0 ? (
                <div className="animate-in fade-in duration-300 mb-6 bg-zinc-50 dark:bg-zinc-800/50 p-4 rounded-xl border border-zinc-200 dark:border-zinc-700/50">
                  <div className="flex justify-between text-xs font-semibold mb-2">
                    <span className="text-emerald-600 dark:text-emerald-400">Downloading AI Knowledge...</span>
                    <span className="text-zinc-500 dark:text-zinc-400">{downloadProgress}%</span>
                  </div>
                  <div className="w-full bg-zinc-200 dark:bg-zinc-700 rounded-full h-3 mb-4 overflow-hidden border border-zinc-300 dark:border-zinc-600">
                    <div
                      className="bg-emerald-500 h-3 transition-all duration-300 ease-out"
                      style={{ width: `${downloadProgress}%` }}
                    ></div>
                  </div>
                  <div className="space-y-2">
                    <p className={`text-xs flex items-center gap-2 ${downloadProgress > 0 ? 'text-emerald-600 dark:text-emerald-400 font-medium' : 'text-zinc-500 dark:text-zinc-400'}`}>
                      {downloadProgress > 0 && <CheckCircle2 className="w-3.5 h-3.5" />} 1. Downloading AI Knowledge...
                    </p>
                    <p className={`text-xs flex items-center gap-2 ${downloadProgress >= 99 ? 'text-emerald-600 dark:text-emerald-400 font-medium' : 'text-zinc-500 dark:text-zinc-400'}`}>
                      {downloadProgress >= 99 && <CheckCircle2 className="w-3.5 h-3.5" />} 2. Saving to safe offline storage...
                    </p>
                    <p className={`text-xs flex items-center gap-2 ${downloadProgress === 100 ? 'text-emerald-600 dark:text-emerald-400 font-medium' : 'text-zinc-500 dark:text-zinc-400'}`}>
                      {downloadProgress === 100 && <CheckCircle2 className="w-3.5 h-3.5" />} 3. Awakening Assistant.
                    </p>
                  </div>
                </div>
              ) : (
                <div className="animate-in fade-in duration-300 mb-6">
                  <button onClick={handleDownloadModel} className="w-full bg-emerald-600 hover:bg-emerald-700 text-white font-semibold py-3 px-4 rounded-xl transition-colors flex items-center justify-center gap-2 shadow-sm">
                    <Download className="w-5 h-5" /> Get Knowledge Automatically
                  </button>
                </div>
              )}

              <button
                onClick={() => setStep(3)}
                disabled={downloadProgress < 100 && isModelDownloading}
                className="w-full bg-zinc-900 hover:bg-zinc-800 dark:bg-zinc-100 dark:hover:bg-white text-white dark:text-zinc-900 font-semibold py-2.5 px-4 rounded-xl transition-colors flex items-center justify-center gap-2 group disabled:opacity-50 disabled:cursor-not-allowed"
              >
                Next: Enable Voice <ArrowRight className="w-4 h-4 group-hover:translate-x-1 transition-transform" />
              </button>
            </div>
          )}

          {step === 3 && (
            <div className="animate-in slide-in-from-right-4 fade-in duration-300">
              <div className="w-12 h-12 bg-blue-100 dark:bg-blue-500/10 text-blue-600 dark:text-blue-400 rounded-xl flex items-center justify-center mb-5 border border-blue-200 dark:border-blue-500/20 shadow-sm">
                <Mic className="w-6 h-6" />
              </div>
              <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">Enable Voice Helper</h2>
              <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-6">
                Enable voice control to talk to Quenderin directly. This allows you to give instructions and record requests entirely offline.
              </p>

              {voiceDownloadProgress === 100 ? (
                <div className="animate-in fade-in duration-300 mb-6 bg-blue-50 dark:bg-blue-900/20 p-4 rounded-xl border border-blue-200 dark:border-blue-800">
                  <div className="flex items-start gap-3">
                    <CheckCircle2 className="w-5 h-5 text-blue-500 shrink-0 mt-0.5" />
                    <div>
                      <p className="text-sm font-semibold text-blue-900 dark:text-blue-300">Voice Helper Ready</p>
                      <p className="text-xs text-blue-700 dark:text-blue-400 mt-1">You can now talk to your assistant offline.</p>
                    </div>
                  </div>
                </div>
              ) : isVoiceDownloading || voiceDownloadProgress > 0 ? (
                <div className="animate-in fade-in duration-300 mb-6 bg-zinc-50 dark:bg-zinc-800/50 p-4 rounded-xl border border-zinc-200 dark:border-zinc-700/50">
                  <div className="flex justify-between text-xs font-semibold mb-2">
                    <span className="text-blue-600 dark:text-blue-400">Installing Voice Helper...</span>
                    <span className="text-zinc-500 dark:text-zinc-400">{voiceDownloadProgress}%</span>
                  </div>
                  <div className="w-full bg-zinc-200 dark:bg-zinc-700 rounded-full h-3 mb-2 overflow-hidden border border-zinc-300 dark:border-zinc-600">
                    <div
                      className="bg-blue-500 h-3 transition-all duration-300 ease-out"
                      style={{ width: `${voiceDownloadProgress}%` }}
                    ></div>
                  </div>
                </div>
              ) : (
                <div className="animate-in fade-in duration-300 mb-6">
                  <button onClick={handleDownloadVoice} className="w-full bg-blue-600 hover:bg-blue-700 text-white font-semibold py-3 px-4 rounded-xl transition-colors flex items-center justify-center gap-2 shadow-sm">
                    <Download className="w-5 h-5" /> Download Voice Engine (50MB)
                  </button>
                </div>
              )}

              <button
                onClick={handleFinish}
                disabled={(voiceDownloadProgress < 100 && isVoiceDownloading) || isFinishing}
                className="w-full bg-zinc-900 hover:bg-zinc-800 dark:bg-zinc-100 dark:hover:bg-white text-white dark:text-zinc-900 font-semibold py-2.5 px-4 rounded-xl transition-colors flex items-center justify-center gap-2 group disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {isFinishing ? "Finishing..." : <>Finish Setup <ArrowRight className="w-4 h-4 group-hover:translate-x-1 transition-transform" /></>}
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
  const [isSidebarOpen, setIsSidebarOpen] = useState(() => {
    if (typeof window === 'undefined') return true;
    const saved = localStorage.getItem('quenderin_sidebar_open');
    if (saved !== null) return saved === 'true';
    return window.innerWidth >= 1280;
  });

  const setSidebarOpen = (open: boolean) => {
    setIsSidebarOpen(open);
    localStorage.setItem('quenderin_sidebar_open', String(open));
  };
  const [isInspectorOpen, setIsInspectorOpen] = useState(false);
  const [currentView, setCurrentView] = useState<'chat' | 'docs' | 'general_chat' | 'metrics' | 'settings'>('general_chat');
  const [activeModel, setActiveModel] = useState<string>('Loading Model...');
  const [showOnboarding, setShowOnboarding] = useState(false);
  const [isLocked, setIsLocked] = useState(false);
  const [forceShowTroubleshooter, setForceShowTroubleshooter] = useState(false);
  const [healthData, setHealthData] = useState<{
    contextOptions?: number[];
    recommendedModelId?: string;
    hardware?: { tier: string; arch: string; isArm: boolean; cpuCores: number };
  } | null>(null);
  const [readiness, setReadiness] = useState<{ ready: boolean; stage: string } | null>(null);

  useEffect(() => {
    // Check initial launch flag
    if (!localStorage.getItem('quenderin_setup_complete')) {
      setShowOnboarding(true);
    }

    const fetchHealth = async () => {
      try {
        // Fallback to exactly port 3000 mapped across the local Node backend
        const res = await fetch('/health');
        if (res.ok) {
          const data = await res.json();
          setHealthData(data);
          if (data.activeModel) setActiveModel(data.activeModel);
          if (data.isBrainInstalled) {
            localStorage.setItem('quenderin_setup_complete', 'true');
            setShowOnboarding(false);
          }
        }
      } catch {
        // Silent block for dev environment cross-origin resets
      }
    };
    const fetchReadiness = async () => {
      try {
        const res = await fetch('/ready');
        const data = await res.json();
        if (typeof data?.ready === 'boolean') {
          setReadiness({ ready: data.ready, stage: String(data.stage ?? 'unknown') });
        }
      } catch {
        setReadiness({ ready: false, stage: 'offline' });
      }
    };
    fetchHealth();
    fetchReadiness();

    const readinessPoll = setInterval(fetchReadiness, 5000);
    return () => clearInterval(readinessPoll);
  }, []);

  const { wsReady, logs, status, currentUI, requiredAction, downloadProgress, settings, activePresetId, sendGoal, sendChatMessage, resetSession, clearRequiredAction, updateSettings, resetSettings, switchPreset, manualVoiceStart, manualVoiceStop } = useAgentSocket();

  const { setDarkMode } = useTheme();

  useEffect(() => {
    if (settings.themePreference === 'dark') setDarkMode(true);
    else if (settings.themePreference === 'light') setDarkMode(false);
    else {
      const isDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
      setDarkMode(isDark);
    }
  }, [settings.themePreference, setDarkMode]);

  useEffect(() => {
    if (settings.privacyLockEnabled && settings.privacyPassphrase) {
      setIsLocked(true);
    } else {
      setIsLocked(false);
    }
  }, [settings.privacyLockEnabled, settings.privacyPassphrase]);

  useEffect(() => {
    if (!requiredAction) {
      setForceShowTroubleshooter(false);
    }
  }, [requiredAction]);

  const handleStartAgent = (g: string, attachments: { name: string, content: string }[] = []) => {
    const sent = sendGoal(g, attachments);
    if (sent) {
      setCurrentView('chat');
      setGoal('');
    }
  };

  const handleSendChat = (m: string, attachments: { name: string, content: string }[] = []) => {
    const sent = sendChatMessage(m, attachments);
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
  useEffect(() => {
    if (currentUI.length > 0 && !isInspectorOpen && status === 'running') {
      setIsInspectorOpen(true);
    }
  }, [currentUI, isInspectorOpen, status]);

  const dismissOnboarding = () => {
    localStorage.setItem('quenderin_setup_complete', 'true');
    setShowOnboarding(false);
  };

  const handleTriggerDownload = async (modelId?: string) => {
    try {
      await fetch('/api/models/download', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ modelId: modelId ?? healthData?.recommendedModelId ?? 'llama32-1b' })
      });
    } catch (e) {
      console.error("Failed to sequence download routing from parent", e);
    }
  };

  return (
    <>
      <PrivacyLock
        isEnabled={settings.privacyLockEnabled && isLocked}
        expectedPassphrase={settings.privacyPassphrase}
        onUnlock={() => setIsLocked(false)}
      />
      {showOnboarding && <WelcomeWizard onDismiss={dismissOnboarding} downloadProgress={downloadProgress} />}
      {requiredAction && (requiredAction.code !== 'OOM_PREVENTION' || forceShowTroubleshooter) &&
        <TroubleshooterGuide
          action={requiredAction}
          onResolved={() => {
            clearRequiredAction();
            setForceShowTroubleshooter(false);
          }}
          downloadProgress={downloadProgress}
          onTriggerDownload={handleTriggerDownload}
          recommendedModelId={healthData?.recommendedModelId}
        />
      }

      <div className={`relative flex h-screen w-full bg-white dark:bg-[#09090b] overflow-hidden selection:bg-purple-500/30 font-sans text-zinc-900 dark:text-zinc-200 transition-all duration-700 ${showOnboarding || (requiredAction && (requiredAction.code !== 'OOM_PREVENTION' || forceShowTroubleshooter)) ? 'blur-xl pointer-events-none opacity-50 scale-[0.99] translate-y-2' : ''}`}>

        {/* Mobile Scrims */}
        {isSidebarOpen && (
          <div
            className="fixed inset-0 bg-black/50 z-30 xl:hidden backdrop-blur-sm transition-opacity"
            onClick={() => setSidebarOpen(false)}
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
          readinessStage={readiness?.stage}
          readinessReady={readiness?.ready}
          currentView={currentView}
          setCurrentView={(v) => {
            // Reset session when switching between agent and chat modes
            if ((v === 'chat' && currentView === 'general_chat') || (v === 'general_chat' && currentView === 'chat')) {
              resetSession();
            }
            setCurrentView(v);
            if (window.innerWidth < 1280) setSidebarOpen(false);
          }}
          onNewGoal={() => {
            handleNewGoal();
            if (window.innerWidth < 1280) setSidebarOpen(false);
          }}
          activeModel={activeModel}
        />

        <div className="flex-1 flex flex-col relative h-full min-w-0 overflow-hidden bg-white dark:bg-[#18181b] transition-colors duration-300">

          {/* Top Header Navigation */}
          <header className="h-[56px] flex-shrink-0 flex items-center justify-between px-6 bg-white/70 dark:bg-[#09090b]/70 backdrop-blur-xl z-20 border-b border-zinc-200/50 dark:border-white/5 transition-all duration-300">
            <div className="flex items-center gap-3">
              <button
                onClick={() => setSidebarOpen(!isSidebarOpen)}
                className="p-1.5 -ml-1.5 text-zinc-500 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 hover:bg-zinc-100 dark:hover:bg-white/5 rounded-xl transition-all active:scale-95"
              >
                <Menu className="w-5 h-5" />
              </button>
              <span className="font-bold text-zinc-900 dark:text-white text-[15px] pl-1 tracking-tight">Quenderin Agent</span>
            </div>

            <button
              onClick={() => setIsInspectorOpen(!isInspectorOpen)}
              className={`flex items-center gap-2 px-4 py-1.5 text-[12px] font-bold rounded-xl transition-all duration-300 border ${isInspectorOpen ? 'bg-zinc-900 dark:bg-white border-transparent text-white dark:text-zinc-900 shadow-lg shadow-purple-500/10' : 'border-zinc-200/50 dark:border-white/5 text-zinc-500 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 hover:bg-zinc-100 dark:hover:bg-white/5 shadow-sm'}`}
            >
              {isInspectorOpen ? <PanelRightClose className="w-4 h-4" /> : <PanelRightOpen className="w-4 h-4" />}
              <span className="hidden sm:inline">Device Inspector</span>
              {currentUI.length > 0 && <span className="flex w-2 h-2 rounded-full bg-blue-500 shadow-[0_0_10px_rgba(59,130,246,0.6)] ml-1 animate-pulse"></span>}
            </button>
          </header>

          {currentView === 'docs' ? (
            <Docs onBack={() => setCurrentView('general_chat')} />
          ) : currentView === 'settings' ? (
            <SettingsArea
              currentSettings={settings}
              onBack={() => setCurrentView('general_chat')}
              onSave={updateSettings}
              onReset={resetSettings}
              contextOptions={healthData?.contextOptions}
              hardwareTier={healthData?.hardware?.tier}
              onThemeChange={(pref) => {
                // Apply immediately to DOM
                if (pref === 'dark') setDarkMode(true);
                else if (pref === 'light') setDarkMode(false);
                else setDarkMode(window.matchMedia('(prefers-color-scheme: dark)').matches);
                // Also persist immediately — don't wait for "Apply Changes"
                updateSettings({ ...settings, themePreference: pref });
              }}
            />
          ) : currentView === 'metrics' ? (
            <Metrics onBack={() => setCurrentView('general_chat')} />
          ) : currentView === 'general_chat' ? (
            <GeneralChatArea
              logs={logs}
              status={status}
              requiredAction={requiredAction}
              onOpenSettings={() => setCurrentView('settings')}
              onOpenTroubleshooter={() => setForceShowTroubleshooter(true)}
              chatInput={chatInput}
              setChatInput={setChatInput}
              onSend={handleSendChat}
              onVoiceStart={manualVoiceStart}
              onVoiceStop={manualVoiceStop}
              activePresetId={activePresetId}
              onSwitchPreset={switchPreset}
            />
          ) : (
            <ChatArea
              logs={logs}
              status={status}
              goal={goal}
              setGoal={setGoal}
              onStart={handleStartAgent}
              setCurrentView={setCurrentView}
              onVoiceStart={manualVoiceStart}
              onVoiceStop={manualVoiceStop}
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
