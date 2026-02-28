import React, { createContext, useContext, useState, useEffect } from 'react';

type ThemeContextType = {
    isDarkMode: boolean;
    toggleTheme: () => void;
    setDarkMode: (isDark: boolean) => void;
};

const ThemeContext = createContext<ThemeContextType | undefined>(undefined);

/** Read saved theme preference from localStorage and resolve to a boolean. */
function resolveInitialDark(): boolean {
    try {
        const saved = localStorage.getItem('quenderin_settings');
        if (saved) {
            const { themePreference } = JSON.parse(saved) as { themePreference?: string };
            if (themePreference === 'dark') return true;
            if (themePreference === 'light') return false;
            // 'system' or missing — fall through to OS query
        }
    } catch { /* ignore parse errors */ }
    return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

export function ThemeProvider({ children }: { children: React.ReactNode }) {
    const [isDarkMode, setIsDarkMode] = useState<boolean>(resolveInitialDark);

    // Apply class to <html> whenever isDarkMode changes
    useEffect(() => {
        if (isDarkMode) {
            document.documentElement.classList.add('dark');
        } else {
            document.documentElement.classList.remove('dark');
        }
    }, [isDarkMode]);

    // Listen for OS-level preference changes (applies when mode is 'system')
    useEffect(() => {
        const mq = window.matchMedia('(prefers-color-scheme: dark)');
        const handler = (e: MediaQueryListEvent) => {
            try {
                const saved = localStorage.getItem('quenderin_settings');
                const pref = saved ? (JSON.parse(saved) as { themePreference?: string }).themePreference : 'system';
                if (!pref || pref === 'system') {
                    setIsDarkMode(e.matches);
                }
            } catch { setIsDarkMode(e.matches); }
        };
        mq.addEventListener('change', handler);
        return () => mq.removeEventListener('change', handler);
    }, []);

    const toggleTheme = () => setIsDarkMode(prev => !prev);
    const setDarkMode = (isDark: boolean) => setIsDarkMode(isDark);

    return (
        <ThemeContext.Provider value={{ isDarkMode, toggleTheme, setDarkMode }}>
            {children}
        </ThemeContext.Provider>
    );
}

export function useTheme() {
    const context = useContext(ThemeContext);
    if (context === undefined) {
        throw new Error('useTheme must be used within a ThemeProvider');
    }
    return context;
}
