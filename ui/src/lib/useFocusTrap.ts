import { useEffect, useRef } from 'react';

/**
 * Modal focus management (r11 backlog #5): moves focus INTO the dialog on open, wraps Tab /
 * Shift+Tab inside it, and RESTORES focus to the opener on close — `aria-modal` alone hides
 * content from the accessibility tree but does nothing about the keyboard.
 *
 * Attach the returned ref to the dialog panel (it gets `tabIndex={-1}` focus as the fallback
 * when the panel has no focusable children yet).
 */
const FOCUSABLE = 'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])';

export function useFocusTrap<T extends HTMLElement>(active: boolean = true): React.RefObject<T> {
    // The null! initial matches React's own RefObject<T> convention for DOM refs — the element
    // exists for the whole life of the effect (the dialog IS the ref'd node).
    const panelRef = useRef<T>(null!);

    useEffect(() => {
        if (!active) return;
        const panel = panelRef.current;
        if (!panel) return;
        const opener = document.activeElement as HTMLElement | null;

        // Initial focus: first focusable child, else the panel itself.
        const first = panel.querySelector<HTMLElement>(FOCUSABLE);
        (first ?? panel).focus();

        const onKeyDown = (e: KeyboardEvent) => {
            if (e.key !== 'Tab') return;
            const focusables = [...panel.querySelectorAll<HTMLElement>(FOCUSABLE)]
                .filter(el => el.offsetParent !== null); // skip display:none branches
            if (focusables.length === 0) { e.preventDefault(); panel.focus(); return; }
            const firstEl = focusables[0];
            const lastEl = focusables[focusables.length - 1];
            const active = document.activeElement;
            if (e.shiftKey && (active === firstEl || active === panel)) {
                e.preventDefault(); lastEl.focus();
            } else if (!e.shiftKey && active === lastEl) {
                e.preventDefault(); firstEl.focus();
            }
        };
        panel.addEventListener('keydown', onKeyDown);
        return () => {
            panel.removeEventListener('keydown', onKeyDown);
            // Restore focus to whatever opened the dialog — losing focus to <body> strands
            // keyboard users at the top of the page.
            opener?.focus?.();
        };
    }, [active]);

    return panelRef;
}
