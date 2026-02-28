// =============================================================================
// Theme hook — resolves system/light/dark → concrete colors + shadows
// Pattern adopted from off-grid-mobile
// =============================================================================

import { useColorScheme } from 'react-native';
import {
  ThemeColors,
  ThemeShadows,
  COLORS_LIGHT,
  COLORS_DARK,
  SHADOWS_LIGHT,
  SHADOWS_DARK,
} from './palettes';
import { useAppStore } from '../stores/appStore';

export interface Theme {
  colors: ThemeColors;
  shadows: ThemeShadows;
  isDark: boolean;
}

export function useTheme(): Theme {
  const systemScheme = useColorScheme();
  const themePreference = useAppStore((s) => s.settings.themePreference);

  const isDark =
    themePreference === 'dark'
      ? true
      : themePreference === 'light'
        ? false
        : systemScheme === 'dark';

  return {
    colors: isDark ? COLORS_DARK : COLORS_LIGHT,
    shadows: isDark ? SHADOWS_DARK : SHADOWS_LIGHT,
    isDark,
  };
}

export type { ThemeColors, ThemeShadows } from './palettes';
