// =============================================================================
// App Store — settings + connection state (persisted to AsyncStorage)
// =============================================================================

import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { AppSettings, DEFAULT_SETTINGS } from '../types';

export type ConnectionStatus = 'disconnected' | 'connecting' | 'connected';

interface AppState {
  // Settings
  settings: AppSettings;
  updateSettings: (patch: Partial<AppSettings>) => void;

  // Connection
  connectionStatus: ConnectionStatus;
  serverUrl: string;
  setConnectionStatus: (s: ConnectionStatus) => void;
  setServerUrl: (url: string) => void;

  // Onboarding
  hasCompletedOnboarding: boolean;
  completeOnboarding: () => void;
}

export const useAppStore = create<AppState>()(
  persist(
    (set) => ({
      // Settings
      settings: { ...DEFAULT_SETTINGS },
      updateSettings: (patch) =>
        set((state) => ({
          settings: { ...state.settings, ...patch },
        })),

      // Connection
      connectionStatus: 'disconnected',
      serverUrl: 'ws://localhost:3002',
      setConnectionStatus: (connectionStatus) => set({ connectionStatus }),
      setServerUrl: (serverUrl) => set({ serverUrl }),

      // Onboarding
      hasCompletedOnboarding: false,
      completeOnboarding: () => set({ hasCompletedOnboarding: true }),
    }),
    {
      name: 'quenderin-app-storage',
      storage: createJSONStorage(() => AsyncStorage),
      partialize: (state) => ({
        settings: state.settings,
        serverUrl: state.serverUrl,
        hasCompletedOnboarding: state.hasCompletedOnboarding,
      }),
    },
  ),
);
