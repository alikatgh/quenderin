// =============================================================================
// useThemedStyles — memoized StyleSheet factory that recomputes on theme change
// Pattern adopted from off-grid-mobile
// =============================================================================

import { useMemo } from 'react';
import { StyleSheet } from 'react-native';
import { useTheme, ThemeColors, ThemeShadows } from './index';

type StyleFactory<T extends StyleSheet.NamedStyles<T>> = (
  colors: ThemeColors,
  shadows: ThemeShadows,
) => T;

export function useThemedStyles<T extends StyleSheet.NamedStyles<T>>(
  factory: StyleFactory<T>,
): T {
  const { colors, shadows, isDark } = useTheme();
  return useMemo(
    () => StyleSheet.create(factory(colors, shadows)),
    [isDark], // only recompute on theme toggle
  );
}
