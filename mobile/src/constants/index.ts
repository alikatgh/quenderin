// =============================================================================
// Quenderin Mobile — Design Tokens (theme-independent)
// Adopted from off-grid-mobile's spacing + typography approach
// =============================================================================

export const SPACING = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
} as const;

export const FONTS = {
  regular: 'System',
  medium: 'System',
  semibold: 'System',
  bold: 'System',
  mono: 'Menlo',
} as const;

export const TYPOGRAPHY = {
  display: { fontSize: 24, fontWeight: '200' as const },
  h1: { fontSize: 22, fontWeight: '600' as const },
  h2: { fontSize: 17, fontWeight: '600' as const },
  h3: { fontSize: 15, fontWeight: '600' as const },
  body: { fontSize: 15, fontWeight: '400' as const },
  bodySmall: { fontSize: 13, fontWeight: '400' as const },
  label: { fontSize: 11, fontWeight: '600' as const, letterSpacing: 0.5 },
  labelSmall: { fontSize: 10, fontWeight: '600' as const, letterSpacing: 0.8 },
  meta: { fontSize: 11, fontWeight: '400' as const },
  metaSmall: { fontSize: 9, fontWeight: '400' as const },
  code: { fontSize: 13, fontWeight: '400' as const, fontFamily: 'Menlo' },
} as const;

export const BORDER_RADIUS = {
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  full: 999,
} as const;

// WebSocket & API config
export const WS_RECONNECT_DELAY_MS = 2000;
export const MAX_ATTACHMENT_SIZE_BYTES = 1024 * 1024; // 1MB
export const TOKEN_BATCH_INTERVAL_MS = 50; // ~20 FPS for streaming
export const CHAT_LOG_DEDUPE_WINDOW_MS = 1000;
export const MAX_MARKDOWN_RENDER_CHARS = 20000;
