import { useState, useEffect, useRef, lazy, Suspense } from 'react';
import { Menu, PanelRightClose, PanelRightOpen } from 'lucide-react';
import { useAgentSocket } from './hooks/useAgentSocket.js';
import { apiFetch, hasAuthToken } from './lib/api.js';
import { ThemeProvider } from './context/ThemeContext.js';
import { Sidebar } from './components/Sidebar.js';
import { ChatArea } from './components/ChatArea.js';
import { GeneralChatArea } from './components/GeneralChatArea.js';
import { TasksArea } from './components/TasksArea.js';
import { ImageGenerationArea } from './components/ImageGenerationArea.js';
import { VisionArea } from './components/VisionArea.js';
import { TroubleshooterGuide } from './components/TroubleshooterGuide.js';
import { useTheme } from './context/ThemeContext.js';
import { PrivacyLock } from './components/PrivacyLock.js';
import { ErrorBoundary } from './components/ErrorBoundary.js';
import { hashPassphrase, isPassphraseHash } from './lib/passphrase.js';
import { useFocusTrap } from './lib/useFocusTrap.js';
import { WelcomeChatModelStep } from './components/onboarding/WelcomeChatModelStep.js';
import { VoiceModelStep } from './components/onboarding/VoiceModelStep.js';
import { useSpeechSetup, type SpeechSetup } from './lib/speech/useSpeechSetup.js';
import { isSpeechDownloadActive } from './lib/speech/useSpeechDownload.js';
import { DownloadStatus } from './vendor/handy/components/onboarding/DownloadStatus.js';

// Lazy-load heavy components — they import syntax highlighter, markdown,
// and data-fetching code that isn't needed on initial render.
const Inspector = lazy(() => import('./components/Inspector.js').then(m => ({ default: m.Inspector })));
const Docs = lazy(() => import('./components/Docs.js').then(m => ({ default: m.Docs })));
const Metrics = lazy(() => import('./components/Metrics.js').then(m => ({ default: m.Metrics })));
const SettingsArea = lazy(() => import('./components/SettingsArea.js').then(m => ({ default: m.SettingsArea })));

/** Lightweight fallback while lazy components load */
function LazyFallback() {
  return <div className="flex items-center justify-center h-full text-zinc-400 dark:text-zinc-500 text-sm">Loading...</div>;
}

export function WelcomeWizard({ onDismiss, onImages, onVision, downloadProgress, downloadModelId, recommendedModelId, speech }: {
  onDismiss: () => void;
  onImages: () => void;
  onVision: () => void;
  downloadProgress: number;
  downloadModelId: string | null;
  recommendedModelId?: string;
  speech: SpeechSetup;
}) {
  const [step, setStep] = useState(1);
  const panelRef = useFocusTrap<HTMLDivElement>();

  return (
    <div className="fixed inset-0 z-[100] flex items-center justify-center bg-black/55 p-4" role="dialog" aria-modal="true" aria-label="Welcome Setup Wizard">
      <div ref={panelRef} tabIndex={-1} className={`max-h-[calc(100dvh-2rem)] w-full overflow-auto rounded-2xl border border-zinc-200 bg-white text-zinc-900 shadow-xl dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-100 ${step === 1 ? 'max-w-md' : 'max-w-xl'}`}>
        <div role="progressbar" aria-valuenow={step} aria-valuemin={1} aria-valuemax={2} aria-label="Setup step" className="h-1 w-full bg-zinc-100 dark:bg-zinc-800">
          <div className="h-full bg-qteal-500 motion-safe:transition-all" style={{ width: `${step * 50}%` }} />
        </div>
        <div className="p-4 sm:p-6">
          {step === 1
            ? <WelcomeChatModelStep onContinue={() => setStep(2)} onImages={onImages} onVision={onVision}
                recommendedModelId={recommendedModelId} downloadingId={downloadModelId} progress={downloadProgress} />
            : <VoiceModelStep speech={speech} onFinish={onDismiss} />}
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
    try {
      const saved = localStorage.getItem('quenderin_sidebar_open');
      if (saved !== null) return saved === 'true';
    } catch { /* localStorage may be unavailable in private/embedded contexts */ }
    return window.innerWidth >= 1280;
  });

  const setSidebarOpen = (open: boolean) => {
    setIsSidebarOpen(open);
    try { localStorage.setItem('quenderin_sidebar_open', String(open)); } catch { /* best-effort */ }
  };
  const [isInspectorOpen, setIsInspectorOpen] = useState(false);
  const [currentView, setCurrentView] = useState<'chat' | 'docs' | 'general_chat' | 'metrics' | 'settings' | 'tasks' | 'images' | 'vision'>('general_chat');
  const [activeModel, setActiveModel] = useState<string>('Loading Model...');
  const [showOnboarding, setShowOnboarding] = useState(false);
  const [isLocked, setIsLocked] = useState(false);
  const [forceShowTroubleshooter, setForceShowTroubleshooter] = useState(false);
  // Q-526: capture token presence once on mount (authToken() is cached + strips the URL on first read).
  // Without a token every protected route 401s opaquely — surface a relaunch banner instead.
  const [tokenPresent] = useState(() => hasAuthToken());
  const [tokenBannerDismissed, setTokenBannerDismissed] = useState(false);
  const [healthData, setHealthData] = useState<{
    contextOptions?: number[];
    recommendedModelId?: string;
    hardware?: { tier: string; arch: string; isArm: boolean; cpuCores: number };
  } | null>(null);
  const [readiness, setReadiness] = useState<{ ready: boolean; stage: string } | null>(null);
  const [showRecoveryBanner, setShowRecoveryBanner] = useState(false);
  const [lastOutageMs, setLastOutageMs] = useState(0);
  const [lastOutageInfo, setLastOutageInfo] = useState<{ seconds: number; recoveredAt: string } | null>(() => {
    if (typeof window === 'undefined') return null;
    try {
      const raw = localStorage.getItem('quenderin_last_outage');
      if (!raw) return null;
      const parsed = JSON.parse(raw) as { seconds?: number; recoveredAt?: string };
      if (typeof parsed.seconds === 'number' && typeof parsed.recoveredAt === 'string') {
        return { seconds: parsed.seconds, recoveredAt: parsed.recoveredAt };
      }
    } catch { /* localStorage or JSON parse failure — ignore */ }
    return null;
  });
  const previousReadyRef = useRef<boolean | null>(null);
  const outageStartRef = useRef<number | null>(null);

  useEffect(() => {
    // Check initial launch flag
    try {
      if (!localStorage.getItem('quenderin_setup_complete')) {
        setShowOnboarding(true);
      }
    } catch { setShowOnboarding(true); }

    const fetchHealth = async () => {
      try {
        // Fallback to exactly port 3000 mapped across the local Node backend
        const res = await fetch('/health');
        if (res.ok) {
          const data = await res.json();
          setHealthData(data);
          if (data.activeModel) setActiveModel(data.activeModel);
        }
      } catch {
        // Silent block for dev environment cross-origin resets
      }
    };
    let cancelled = false;
    let readinessTimer: ReturnType<typeof setTimeout> | null = null;
    let readinessFailureCount = 0;

    const BASE_READINESS_POLL_MS = 5000;
    const MAX_READINESS_POLL_MS = 30000;

    const nextReadinessDelay = () => {
      if (readinessFailureCount <= 0) return BASE_READINESS_POLL_MS;
      const step = Math.min(3, readinessFailureCount - 1); // 5s, 10s, 20s, 30s
      return Math.min(MAX_READINESS_POLL_MS, BASE_READINESS_POLL_MS * (2 ** step));
    };

    const scheduleReadinessPoll = () => {
      if (cancelled) return;
      readinessTimer = setTimeout(fetchReadiness, nextReadinessDelay());
    };

    const fetchReadiness = async () => {
      try {
        const res = await fetch('/ready', { cache: 'no-store' });
        const data = await res.json();
        if (cancelled) return;
        if (typeof data?.ready === 'boolean') {
          readinessFailureCount = 0;
          setReadiness({ ready: data.ready, stage: String(data.stage ?? 'unknown') });
        } else {
          throw new Error('Invalid readiness response');
        }
      } catch {
        if (cancelled) return;
        readinessFailureCount += 1;
        const retrySeconds = Math.round(nextReadinessDelay() / 1000);
        setReadiness({ ready: false, stage: `retrying in ${retrySeconds}s` });
      } finally {
        scheduleReadinessPoll();
      }
    };
    fetchHealth();
    fetchReadiness();

    return () => {
      cancelled = true;
      if (readinessTimer) clearTimeout(readinessTimer);
    };
  }, []);

  const { wsReady, speechDownloadEvents, downloadModelId, logs, status, currentUI, requiredAction, downloadProgress, settings, activePresetId, agentPaused, sendGoal, sendChatMessage, resetSession, clearRequiredAction, updateSettings, resetSettings, switchPreset, pauseAgent, resumeAgent, stopChat, loadSession, taskStatus, taskLog, taskApproval, taskUndoable, startTask, answerTaskApproval, stopTask, undoTask, missionApproval, answerMissionApproval } = useAgentSocket();
  const speech = useSpeechSetup(wsReady, speechDownloadEvents);
  const voiceModelId = speech.settings?.voiceEnabled
    ? speech.catalog?.models.find(row => row.model.id === speech.settings?.modelId && row.installed && row.engine.compatibility === 'supported')?.model.id
    : undefined;
  const openVoiceSettings = () => {
    setCurrentView('settings');
    requestAnimationFrame(() => document.getElementById('voice-settings-heading')?.scrollIntoView({ block: 'center' }));
  };


  const { setDarkMode } = useTheme();

  const applyTheme = (pref: string) => {
    if (pref === 'dark') setDarkMode(true);
    else if (pref === 'light') setDarkMode(false);
    else setDarkMode(window.matchMedia('(prefers-color-scheme: dark)').matches);
  };

  useEffect(() => {
    if (typeof readiness?.ready !== 'boolean') return;
    const wasReady = previousReadyRef.current;
    if (readiness.ready === false && outageStartRef.current === null) {
      outageStartRef.current = Date.now();
    }
    if (wasReady === false && readiness.ready === true) {
      const outageMs = outageStartRef.current ? Date.now() - outageStartRef.current : 0;
      setLastOutageMs(outageMs);
      const outageSeconds = Math.max(1, Math.round(outageMs / 1000));
      const summary = { seconds: outageSeconds, recoveredAt: new Date().toISOString() };
      setLastOutageInfo(summary);
      try { localStorage.setItem('quenderin_last_outage', JSON.stringify(summary)); } catch { /* best-effort */ }
      outageStartRef.current = null;
      setShowRecoveryBanner(true);
    }
    if (wasReady === true && readiness.ready === true) {
      outageStartRef.current = null;
    }
    previousReadyRef.current = readiness.ready;
  }, [readiness?.ready]);

  useEffect(() => {
    if (!showRecoveryBanner) return;
    const timer = setTimeout(() => setShowRecoveryBanner(false), 3000);
    return () => clearTimeout(timer);
  }, [showRecoveryBanner]);

  useEffect(() => {
    applyTheme(settings.themePreference);
  }, [settings.themePreference, setDarkMode]);

  const lockConfiguredRef = useRef(false);
  useEffect(() => {
    const configured = settings.privacyLockEnabled && !!settings.privacyPassphrase;
    // Engage the lock only on the TRANSITION to "configured" (initial mount with the lock on, or the
    // user newly enabling it) — not on every settings sync, which would re-lock an app the user has
    // already unlocked mid-session (deep-hunt). Disabling the lock always unlocks.
    if (configured && !lockConfiguredRef.current) {
      setIsLocked(true);
    } else if (!configured) {
      setIsLocked(false);
    }
    lockConfiguredRef.current = configured;
  }, [settings.privacyLockEnabled, settings.privacyPassphrase]);

  // Always-latest settings, so the async migration below merges into the CURRENT settings, not the stale
  // snapshot its closure captured (adversarial-verify P2: reverting a field changed during the hash window).
  const settingsRef = useRef(settings);
  settingsRef.current = settings;

  // Q-530: one-time migration — a passphrase persisted before Q-530 is PLAINTEXT in localStorage. Hash
  // it and re-persist so the plaintext is scrubbed. Idempotent (isPassphraseHash guard) and gated by a
  // ref so it fires once; PrivacyLock still accepts the plaintext until this lands, so nobody is locked
  // out in the interim. On failure the ref resets so a later load can retry.
  const passphraseMigratedRef = useRef(false);
  useEffect(() => {
    const pp = settings.privacyPassphrase;
    if (!pp || isPassphraseHash(pp) || passphraseMigratedRef.current) return;
    passphraseMigratedRef.current = true;
    hashPassphrase(pp)
      // Merge into settingsRef.current (latest), NOT the closure's `settings`: hashing is async, and any
      // other setting changed during that window must not be clobbered by a stale-snapshot re-persist.
      .then(h => updateSettings({ ...settingsRef.current, privacyPassphrase: h }))
      .catch(() => { passphraseMigratedRef.current = false; });
  }, [settings.privacyPassphrase]);

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
    try { localStorage.setItem('quenderin_setup_complete', 'true'); } catch { /* best-effort */ }
    setShowOnboarding(false);
  };

  const handleTriggerDownload = async (modelId?: string) => {
    try {
      await apiFetch('/api/models/download', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ modelId: modelId ?? healthData?.recommendedModelId ?? 'llama32-1b' })
      });
    } catch {
      // Download failure is non-fatal — user can retry from settings
    }
  };

  const outageSeconds = Math.max(1, Math.round(lastOutageMs / 1000));
  const shouldShowSettingsShortcut = lastOutageMs >= 15_000;
  const clearOutageHistory = () => {
    setLastOutageInfo(null);
    setLastOutageMs(0);
    outageStartRef.current = null;
    try { localStorage.removeItem('quenderin_last_outage'); } catch { /* best-effort */ }
  };

  return (
    <>
      <PrivacyLock
        isEnabled={settings.privacyLockEnabled && isLocked}
        expectedPassphrase={settings.privacyPassphrase}
        onUnlock={() => setIsLocked(false)}
      />
      {/* Q-526: a missing per-launch token means every protected route 401s — tell the user WHY and how
          to fix it (relaunch) instead of leaving the app silently broken. */}
      {!tokenPresent && !tokenBannerDismissed && (
        <div role="alert" className="fixed top-0 inset-x-0 z-[998] flex items-center justify-center gap-3 px-4 py-2.5 bg-amber-500 text-amber-950 text-[13px] font-medium shadow-md">
          <span>Session token missing — Quenderin can’t reach the local agent. Relaunch it from the launcher (or reopen the link the CLI printed) to reconnect.</span>
          <button onClick={() => setTokenBannerDismissed(true)} className="ml-1 rounded px-2 py-0.5 text-amber-950/70 hover:bg-amber-950/10 transition-colors" aria-label="Dismiss">✕</button>
        </div>
      )}
      {showOnboarding && <WelcomeWizard onDismiss={dismissOnboarding} onImages={() => { setShowOnboarding(false); setCurrentView('images'); }} onVision={() => { setShowOnboarding(false); setCurrentView('vision'); }} downloadProgress={downloadProgress} downloadModelId={downloadModelId} recommendedModelId={healthData?.recommendedModelId} speech={speech} />} 
      {!['images', 'vision'].includes(currentView) && requiredAction && (requiredAction.code !== 'OOM_PREVENTION' || forceShowTroubleshooter) &&
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

      {/* Q-549 Step 3: per-run mission approval before the device agent drives anything. */}
      {missionApproval && (
        <div
          role="dialog"
          aria-modal="true"
          aria-labelledby="mission-approval-title"
          aria-describedby="mission-approval-desc"
          className="fixed inset-0 z-[997] flex items-center justify-center bg-black/50 p-4"
          onKeyDown={(e) => {
            // Escape = Don't allow (fail-closed). Geometry-stable: no layout shift on key.
            if (e.key === 'Escape') {
              e.preventDefault();
              answerMissionApproval(false);
            }
          }}
        >
          <div className="w-full max-w-md rounded-xl border border-zinc-200 bg-white p-5 dark:border-zinc-700 dark:bg-zinc-900">
            <h2 id="mission-approval-title" className="text-base font-semibold text-zinc-900 dark:text-zinc-100">
              Allow this mission?
            </h2>
            <p id="mission-approval-desc" className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
              The local agent wants to drive your device for:
            </p>
            <p className="mt-2 rounded-lg bg-zinc-100 px-3 py-2 text-sm text-zinc-800 dark:bg-zinc-800 dark:text-zinc-200 break-words">
              {missionApproval.goal || '(no goal text)'}
            </p>
            <div className="mt-4 flex justify-end gap-2">
              <button
                type="button"
                autoFocus
                className="rounded-lg px-3 py-2 text-sm text-zinc-700 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-qteal-500"
                onClick={() => answerMissionApproval(false)}
              >
                Don&apos;t allow
              </button>
              <button
                type="button"
                className="rounded-lg bg-qteal-600 px-3 py-2 text-sm font-medium text-white hover:bg-qteal-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-qteal-500"
                onClick={() => answerMissionApproval(true)}
              >
                Allow
              </button>
            </div>
          </div>
        </div>
      )}

      <div className={`relative flex h-screen w-full bg-white dark:bg-background overflow-hidden selection:bg-qteal-500/30 font-sans text-zinc-900 dark:text-zinc-200 transition-all duration-700 motion-reduce:transition-none ${showOnboarding || (!['images', 'vision'].includes(currentView) && requiredAction && (requiredAction.code !== 'OOM_PREVENTION' || forceShowTroubleshooter)) || missionApproval ? 'blur-xl pointer-events-none opacity-50 scale-[0.99] translate-y-2' : ''}`}>

        {/* Mobile Scrims */}
        {isSidebarOpen && (
          <div
            className="fixed inset-0 bg-black/55 z-30 xl:hidden transition-opacity"
            onClick={() => setSidebarOpen(false)}
          />
        )}
        {isInspectorOpen && (
          <div
            className="fixed inset-0 bg-black/55 z-30 md:hidden transition-opacity"
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
          onSelectSession={(id) => {
            // Q-313: open the clicked conversation — load its transcript, THEN switch to the chat view
            // (only on a successful load, so a fetch failure doesn't drop you into an empty screen).
            loadSession(id).then((ok) => {
              if (ok) setCurrentView('general_chat');
              if (window.innerWidth < 1280) setSidebarOpen(false);
            });
          }}
          activeModel={activeModel}
          hardwareTier={healthData?.hardware?.tier}
        />

        <div className="flex-1 flex flex-col relative h-full min-w-0 overflow-hidden bg-white dark:bg-background transition-colors">
          {!showOnboarding && currentView !== 'settings' && Object.values(speech.downloads.snapshots)
            .filter(snapshot => isSpeechDownloadActive(snapshot) || snapshot.phase === 'paused' || snapshot.phase === 'error')
            .map(snapshot => (
              <div key={snapshot.modelId} className="flex shrink-0 items-center justify-between gap-2 border-b border-zinc-200 px-4 py-2 dark:border-zinc-800">
                <DownloadStatus name={speech.catalog?.models.find(row => row.model.id === snapshot.modelId)?.model.name ?? snapshot.modelId} snapshot={snapshot} />
                <button type="button" onClick={openVoiceSettings} className="shrink-0 rounded px-2 py-1 text-xs font-medium text-qteal-700 underline dark:text-qteal-300">Voice settings</button>
              </div>
            ))}


          {showRecoveryBanner && (
            <div role="status" aria-live="polite" className="absolute top-3 right-4 z-30 px-3 py-2 rounded-lg border border-emerald-300/50 dark:border-emerald-500/30 bg-emerald-50 dark:bg-emerald-500/10 text-emerald-700 dark:text-emerald-300 text-xs font-semibold shadow-sm animate-in fade-in slide-in-from-top-2 duration-200 flex items-center gap-2">
              <span className="tabular-nums">Backend recovered and ready{lastOutageMs > 0 ? ` (${outageSeconds}s outage)` : ''}</span>
              {shouldShowSettingsShortcut && (
                <button
                  onClick={() => {
                    setCurrentView('settings');
                    setShowRecoveryBanner(false);
                  }}
                  className="px-2 py-0.5 rounded-md border border-emerald-400/40 dark:border-emerald-500/40 hover:bg-emerald-100 dark:hover:bg-emerald-500/20 transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500"
                >
                  Open Settings
                </button>
              )}
            </div>
          )}

          {/* Top Header */}
          <header className="h-12 flex-shrink-0 flex items-center justify-between px-4 sm:px-5 bg-white dark:bg-background z-20 border-b border-zinc-200/70 dark:border-zinc-800 transition-all">
            <div className="flex items-center gap-2">
              <button
                type="button"
                onClick={() => setSidebarOpen(!isSidebarOpen)}
                aria-label={isSidebarOpen ? 'Close sidebar' : 'Open sidebar'}
                className="p-1.5 -ml-1 text-zinc-400 dark:text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 rounded-lg transition-all"
              >
                <Menu className="w-[18px] h-[18px]" />
              </button>
              <span className="font-semibold text-zinc-800 dark:text-zinc-200 text-[13px] tracking-tight">Quenderin</span>
            </div>

            <button
              type="button"
              onClick={() => setIsInspectorOpen(!isInspectorOpen)}
              aria-label={isInspectorOpen ? 'Close inspector' : 'Open inspector'}
              aria-expanded={isInspectorOpen}
              className={`flex items-center gap-1.5 px-2.5 py-1.5 text-[11px] font-semibold rounded-lg transition-all border ${isInspectorOpen ? 'bg-zinc-100 dark:bg-zinc-800 border-zinc-300/70 dark:border-zinc-700 text-zinc-800 dark:text-zinc-200' : 'border-zinc-200/60 dark:border-zinc-800/60 text-zinc-400 dark:text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 hover:bg-zinc-50 dark:hover:bg-zinc-800/50'}`}
            >
              {isInspectorOpen ? <PanelRightClose className="w-3.5 h-3.5" /> : <PanelRightOpen className="w-3.5 h-3.5" />}
              <span className="hidden sm:inline">Inspector</span>
              {currentUI.length > 0 && <span className="flex w-1.5 h-1.5 rounded-full bg-blue-500 ml-0.5 motion-safe:animate-pulse" />}
            </button>
          </header>

          <div className={currentView === 'images' ? 'flex flex-1 min-h-0' : 'hidden'}>
            <ErrorBoundary fallbackLabel="Images"><ImageGenerationArea active={currentView === 'images'} /></ErrorBoundary>
          </div>
          <div className={currentView === 'vision' ? 'flex flex-1 min-h-0' : 'hidden'}>
            <ErrorBoundary fallbackLabel="Vision"><VisionArea active={currentView === 'vision'} /></ErrorBoundary>
          </div>
          {['images', 'vision'].includes(currentView) ? null : currentView === 'docs' ? (
            <ErrorBoundary fallbackLabel="Docs">
            <Suspense fallback={<LazyFallback />}>
              <Docs onBack={() => setCurrentView('general_chat')} />
            </Suspense>
            </ErrorBoundary>
          ) : currentView === 'settings' ? (
            <ErrorBoundary fallbackLabel="Settings">
            <Suspense fallback={<LazyFallback />}>
            <SettingsArea
              voice={speech}
              currentSettings={settings}
              onBack={() => setCurrentView('general_chat')}
              onSave={updateSettings}
              onReset={resetSettings}
              contextOptions={healthData?.contextOptions}
              hardwareTier={healthData?.hardware?.tier}
              lastOutageInfo={lastOutageInfo}
              onClearOutageHistory={clearOutageHistory}
              readinessStage={readiness?.stage}
              onThemeChange={(pref) => {
                // Apply immediately to DOM
                applyTheme(pref);
                // Also persist immediately — don't wait for "Apply Changes"
                updateSettings({ ...settings, themePreference: pref });
              }}
            />
            </Suspense>
            </ErrorBoundary>
          ) : currentView === 'metrics' ? (
            <ErrorBoundary fallbackLabel="Metrics">
            <Suspense fallback={<LazyFallback />}>
              <Metrics onBack={() => setCurrentView('general_chat')} />
            </Suspense>
            </ErrorBoundary>
          ) : currentView === 'tasks' ? (
            <TasksArea
              status={taskStatus}
              log={taskLog}
              approval={taskApproval}
              undoable={taskUndoable}
              wsReady={wsReady}
              onStart={startTask}
              onApprove={answerTaskApproval}
              onStop={stopTask}
              onUndo={undoTask}
            />
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
              onStop={stopChat}
              voice={{ modelId: voiceModelId, onSettings: openVoiceSettings, blocked: !wsReady || showOnboarding || !!missionApproval ||
                (settings.privacyLockEnabled && isLocked) || !!(requiredAction && (requiredAction.code !== 'OOM_PREVENTION' || forceShowTroubleshooter)) }}
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
              voice={{ modelId: voiceModelId, onSettings: openVoiceSettings, blocked: !wsReady || showOnboarding || !!missionApproval ||
                (settings.privacyLockEnabled && isLocked) || !!(requiredAction && (requiredAction.code !== 'OOM_PREVENTION' || forceShowTroubleshooter)) }}
              agentPaused={agentPaused}
              onPause={pauseAgent}
              onResume={resumeAgent}
            />
          )}
        </div>

        {isInspectorOpen && (
          <ErrorBoundary fallbackLabel="Inspector">
          <Suspense fallback={<LazyFallback />}>
            <Inspector
              isOpen={isInspectorOpen}
              currentUI={currentUI}
              logs={logs}
            />
          </Suspense>
          </ErrorBoundary>
        )}

      </div>
    </>
  );
}

/**
 * First-run consent — nobody uses the app without agreeing that AI output is their own
 * responsibility. Same wording as the iOS ConsentView / Android ConsentScreen (twin copy
 * in QuenderinKit SupportContact.swift / quenderin-core SupportContact.kt); update all
 * three together.
 */
function ConsentGate({ children }: { children: React.ReactNode }) {
  const [accepted, setAccepted] = useState<boolean>(() => {
    try { return localStorage.getItem('quenderin_disclaimer_accepted') === 'true'; }
    catch { return false; } // storage unavailable → ask every launch rather than never
  });

  if (accepted) return <>{children}</>;

  const agree = () => {
    try { localStorage.setItem('quenderin_disclaimer_accepted', 'true'); } catch { /* best-effort */ }
    setAccepted(true);
  };

  return (
    <div className="fixed inset-0 z-[200] flex items-center justify-center bg-zinc-100 dark:bg-background p-4" role="dialog" aria-modal="true" aria-label="Use with judgement">
      <div className="w-full max-w-lg bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-2xl p-8">
        <h1 className="text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Use with judgement</h1>
        <dl className="mt-6 space-y-4 text-sm">
          <div>
            <dt className="font-semibold text-zinc-900 dark:text-zinc-100">AI can be wrong</dt>
            <dd className="text-zinc-600 dark:text-zinc-400">On-device models are small. They can be confidently wrong, outdated, or occasionally inappropriate — and nothing filters them.</dd>
          </div>
          <div>
            <dt className="font-semibold text-zinc-900 dark:text-zinc-100">It is not advice</dt>
            <dd className="text-zinc-600 dark:text-zinc-400">Nothing Quenderin writes is medical, legal, financial, or safety advice. Verify anything that matters with a qualified source.</dd>
          </div>
          <div>
            <dt className="font-semibold text-zinc-900 dark:text-zinc-100">You are in charge</dt>
            <dd className="text-zinc-600 dark:text-zinc-400">Every answer is generated and acted on at your own risk and judgement — what you do with it is your decision alone.</dd>
          </div>
        </dl>
        <p className="mt-6 text-xs text-zinc-500 dark:text-zinc-500">
          By continuing you agree: Quenderin is provided &ldquo;as is&rdquo;, and to the maximum extent
          permitted by law, the Quenderin project and its contributors accept no liability, to anyone,
          under any circumstances, for the software or anything its AI models produce.{' '}
          <a href="https://quenderin.org/terms" target="_blank" rel="noreferrer" className="underline">Read the full terms</a>.
        </p>
        <button
          onClick={agree}
          className="mt-6 w-full rounded-full bg-teal-700 hover:bg-teal-800 text-white font-semibold py-3 text-sm"
        >
          I understand and agree
        </button>
      </div>
    </div>
  );
}

export default function App() {
  return (
    <ThemeProvider>
      <ConsentGate>
        <AppContent />
      </ConsentGate>
    </ThemeProvider>
  );
}
