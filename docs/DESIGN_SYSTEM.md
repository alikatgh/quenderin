# Quenderin Design System

The bar (owner's words): **world-class UI on all three clients — Android, iOS, macOS — each in its
platform's native idiom.** The UI *is* the product; "private on-device AI" earns trust through
composure and polish. This doc extends `~/.claude/UI_DESIGN_RULES.md` (which always wins on
conflict) with Quenderin's tokens, components, and per-platform idioms.

## 1. Token twins — ONE source of truth per platform, kept in lockstep

| Tokens | Android | Apple |
|---|---|---|
| Colors, bubble colors, status accent | `android/.../ui/Theme.kt` (`QuenderinColors`, `DarkScheme`) | `apple/.../Theme.swift` (`QuenderinPalette`) |
| Shapes (bubble tails, cards, pills) | `QuenderinShapes` | `BubbleShape` + per-view corner radii |
| Device noun in copy ("phone"/"Mac") | n/a (phone-only) | `deviceNoun` (Theme.swift) |

Key values (change BOTH files or neither):
- Brand `#635BFF`, bright `#8B83FF` · dark bg `#0B0B10` · surface `#16161D` · surfaceVariant `#1E1E27`
- Status green `#37C98B` (dot) / `#8FE8C4` (text) — the "on-device · private" accent
- Bubbles: user `#5D54C4`, assistant = surfaceVariant; 18dp corners, 4dp tail toward the speaker
- Cards: 16dp radius (12 on Apple picker/shortfall cards), hairline borders, **no shadows**

## 2. Component language

- **Status dot + word** is the universal state badge: green "Fits"/"on-device", orange "Tight"/
  "Not enough free space", red "Too big". Never a bare unexplained checkmark.
- **Structured warning card**, never a wall of colored text: status dot + short semibold headline +
  ONE plain-toned sentence carrying the two numbers that matter. (`StorageShortfallCard`, both platforms.)
- **Model picker rows**: title (semibold) · one-line family blurb (`modelBlurb`) · monospaced-digit
  meta ("4.7 GB · Q4_K_M · needs ~6.5 GB RAM") · fit badge right · recommended row gets a
  brand-tinted hairline + "RECOMMENDED FOR THIS DEVICE" tag · ineligible rows dimmed + the reason.
- **Selection reads through COLOR only** — geometry (padding, size, borders-width) is identical in
  every state (speed-dial chips, nav tabs).
- **Markdown in assistant bubbles** (headings, bold, lists, code blocks); user messages stay literal.
- Drawn (Canvas/SF-Symbol) icons only; no icon-font/emoji glyphs in chrome.

## 3. Flow rules (learned, enforced)

- **No dead-end states.** Every screen state has exactly ONE enabled primary action. If the
  recommended model doesn't fit → the primary action *becomes* "Choose a smaller model" (never a
  disabled hero button). Failure states carry "Try again"/"Back to model choice".
- **Downloads are never a trap**: Cancel is always visible; cancel returns to the recommendation
  (a change of mind, not a failure); the `.part` resumes later.
- **Disk preflight before the tap**, not at 95%: `DiskSpace.check` gates the CTA on both platforms.
- **The recommendation is a default, not a cage**: full catalog one tap away everywhere a model is chosen.
- **Speed dial** (Fast/Balanced/Quality → `SpeedPresets`, identical RAM bands in both cores):
  quality = device recommendation; never upside-down (clamped on tiny devices).

## 4. Per-platform idiom

- **Android / iOS (phones)**: WhatsApp-density chat. Conversation LIST is the landing screen
  (avatar + title + relative time; swipe/long-press delete; "+" compose) → tap into the
  conversation (back returns). Composer docks ON the keyboard (`imePadding` +
  `consumeWindowInsets`); bottom nav is a 56dp band, not Material's 80dp default.
- **macOS**: a REAL Mac app, not a phone in a window — `NavigationSplitView` (chats sidebar →
  detail), model identity in the title bar, ⌘N New Chat in the File menu, standard ⌘, Settings
  scene, right-click context menus. Transcript + composer read as a centered ≤760pt column;
  bubbles 460pt (vs 300 on phones).

## 5. Verification protocol (what "done" means for UI)

Compile-clean is NOT done. Verify visually on the real target before claiming done:
S23 screenshots over adb (guard EVERY injected tap with a frontmost-window check — the phone is
shared across sessions), macOS `screencapture` of the app window (never click unless Quenderin is
verifiably frontmost), iOS simulator screenshots. Engine truths surface in UI review — the flat
"User:/Assistant:" prompt bug was caught by *looking* at a Mac reply, not by tests.
