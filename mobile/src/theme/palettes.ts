// =============================================================================
// Quenderin Mobile — Color Palettes
// Purple accent (matching desktop), zinc base, monochrome hierarchy
// =============================================================================

export interface ThemeColors {
  // Backgrounds
  background: string;
  surface: string;
  surfaceLight: string;
  card: string;

  // Text hierarchy
  text: string;
  textSecondary: string;
  textMuted: string;
  textDisabled: string;

  // Accents
  primary: string;
  primaryMuted: string;
  primaryBg: string;

  // Semantic
  success: string;
  successBg: string;
  warning: string;
  warningBg: string;
  error: string;
  errorBg: string;
  info: string;

  // Borders
  border: string;
  borderLight: string;

  // Input
  inputBg: string;
  inputBorder: string;
  inputBorderFocused: string;
  placeholder: string;

  // Misc
  overlay: string;
  skeleton: string;
}

export interface ThemeShadows {
  small: object;
  medium: object;
  large: object;
}

export const COLORS_LIGHT: ThemeColors = {
  background: '#FFFFFF',
  surface: '#F9FAFB',
  surfaceLight: '#F4F4F5',
  card: '#FFFFFF',

  text: '#18181B',
  textSecondary: '#52525B',
  textMuted: '#A1A1AA',
  textDisabled: '#D4D4D8',

  primary: '#7C3AED',
  primaryMuted: '#A78BFA',
  primaryBg: '#F5F3FF',

  success: '#059669',
  successBg: '#ECFDF5',
  warning: '#D97706',
  warningBg: '#FFFBEB',
  error: '#DC2626',
  errorBg: '#FEF2F2',
  info: '#2563EB',

  border: '#E4E4E7',
  borderLight: '#F4F4F5',

  inputBg: '#FFFFFF',
  inputBorder: '#E4E4E7',
  inputBorderFocused: '#7C3AED',
  placeholder: '#A1A1AA',

  overlay: 'rgba(0,0,0,0.4)',
  skeleton: '#F4F4F5',
};

export const COLORS_DARK: ThemeColors = {
  background: '#09090B',
  surface: '#18181B',
  surfaceLight: '#27272A',
  card: '#18181B',

  text: '#FAFAFA',
  textSecondary: '#A1A1AA',
  textMuted: '#71717A',
  textDisabled: '#52525B',

  primary: '#A78BFA',
  primaryMuted: '#7C3AED',
  primaryBg: 'rgba(124, 58, 237, 0.1)',

  success: '#34D399',
  successBg: 'rgba(52, 211, 153, 0.1)',
  warning: '#FBBF24',
  warningBg: 'rgba(251, 191, 36, 0.1)',
  error: '#F87171',
  errorBg: 'rgba(248, 113, 113, 0.1)',
  info: '#60A5FA',

  border: '#27272A',
  borderLight: '#3F3F46',

  inputBg: '#18181B',
  inputBorder: '#3F3F46',
  inputBorderFocused: '#A78BFA',
  placeholder: '#71717A',

  overlay: 'rgba(0,0,0,0.6)',
  skeleton: '#27272A',
};

export const SHADOWS_LIGHT: ThemeShadows = {
  small: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.05,
    shadowRadius: 2,
    elevation: 1,
  },
  medium: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.08,
    shadowRadius: 8,
    elevation: 3,
  },
  large: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.12,
    shadowRadius: 16,
    elevation: 6,
  },
};

export const SHADOWS_DARK: ThemeShadows = {
  small: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.3,
    shadowRadius: 2,
    elevation: 1,
  },
  medium: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.4,
    shadowRadius: 8,
    elevation: 3,
  },
  large: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.5,
    shadowRadius: 16,
    elevation: 6,
  },
};
