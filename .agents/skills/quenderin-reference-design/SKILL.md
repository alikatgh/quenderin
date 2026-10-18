---
name: quenderin-reference-design
description: Design, redesign, or polish Quenderin website and app interfaces using purposeful visual references, real user tasks, and rendered iteration. Use only in this repository; exclude backend/model implementation and unrelated products.
---

# Quenderin reference design

Use this repository-local skill for Quenderin UI work. Match the requested scope: exploration stays read-only, and design guidance does not authorize publication.

## Inspiration

Adapted from [Phil Pitus's October 2026 design thread](https://x.com/pitus_/status/2110059026818212244): choose references deliberately, describe the user's task, explore interaction options, correct spacing and hierarchy through iteration, and finish the states the product actually needs. A first draft is a starting point for judgment. Borrow these working principles, not the thread's illustrations, layouts, or claims about AI authorship.

## Establish a direction

- For a redesign, inspect 3–5 purposeful visual references before choosing the composition. Existing Quenderin screens and user-supplied examples can count. For each, name the specific useful detail and what would be inappropriate here. For bounded polish, reuse relevant references already established rather than restarting research.
- Describe what the visitor needs to understand or accomplish. On the homepage: understand local AI, choose Mac or iPhone, or follow a clear route to details and updates. In the app: choose a model and complete a real chat task.
- Briefly compare plausible interaction approaches when there is a meaningful choice, then choose one concrete composition. Explain hierarchy, spacing, typography, and control placement in terms of that task; vague aesthetic adjectives are not a brief.

## Apply Quenderin's character

- Preserve the user's minimal homepage structure and factual voice. Keep the main product statement, store destinations, detailed overview, latest update, language/theme controls, source, and privacy easy to find. Keep detailed product explanation in `website/tell-me-more.html`.
- Start with the existing Bricolage font, elf identity, teal/copper accents, and neutral surfaces. Use size, alignment, and whitespace for hierarchy. Introduce a container, gradient, illustration, or motion only when it explains something or improves an actual interaction.
- For homepage work, prefer `website/index.html` and `website/simple-home.css`. Preserve shared styles, localization keys, language-aware links, and real destinations unless the task needs a coordinated change. Reuse existing tools and assets before adding dependencies.
- Let actual product behavior carry the design. Avoid feature grids or a simulated live app on the minimal homepage. Never imply tested inference, download progress, store availability, or generated results without corresponding evidence. New artwork must serve the task and follow the project's existing artwork workflow.

## Finish and inspect

- Complete real controls and their hover, focus, active, disabled, or selected states as applicable. For actual asynchronous app work, cover download, verify, load, generate, cancel, and recover from failure. Do not invent loading, empty, or animated states for a static page.
- Render the changed interface and use its relevant controls. Inspect light/dark appearance, narrow widths, long translations and RTL layouts; check keyboard access and reduced motion when affected. Keep these checks proportional to the changed surface.
- Correct visible problems in typography, rhythm, contrast, alignment, wrapping, and interaction feedback. Compare the result with the chosen references and user task, not just a successful build.
- Finish when the requested task is clear, the real interactions work, and the affected layouts have been inspected. Report the concrete design choices and checks, including any verification gap. Keep committed, pushed, deployed, and live-verified states distinct.
