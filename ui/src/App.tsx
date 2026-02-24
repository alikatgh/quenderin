import { useState } from 'react';
import { Menu, PanelRightClose, PanelRightOpen } from 'lucide-react';
import { useAgentSocket } from './hooks/useAgentSocket.js';
import { ThemeProvider } from './context/ThemeContext.js';
import { Sidebar } from './components/Sidebar.js';
import { ChatArea } from './components/ChatArea.js';
import { GeneralChatArea } from './components/GeneralChatArea.js';
import { Inspector } from './components/Inspector.js';
import { Docs } from './components/Docs.js';
import { Metrics } from './components/Metrics.js';

function AppContent() {
  const [goal, setGoal] = useState('');
  const [chatInput, setChatInput] = useState('');
  const [isSidebarOpen, setIsSidebarOpen] = useState(true);
  const [isInspectorOpen, setIsInspectorOpen] = useState(false);
  const [currentView, setCurrentView] = useState<'chat' | 'docs' | 'general_chat' | 'metrics'>('general_chat');

  const { wsReady, logs, status, currentUI, sendGoal, sendChatMessage, resetSession } = useAgentSocket();

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

  return (
    <div className={`flex h-screen w-full bg-white dark:bg-[#18181b] overflow-hidden selection:bg-purple-500/30 font-sans text-zinc-900 dark:text-zinc-200 transition-colors duration-300`}>

      <Sidebar
        isOpen={isSidebarOpen}
        wsReady={wsReady}
        logs={logs}
        currentView={currentView}
        setCurrentView={setCurrentView}
        onNewGoal={handleNewGoal}
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
  );
}

export default function App() {
  return (
    <ThemeProvider>
      <AppContent />
    </ThemeProvider>
  );
}
