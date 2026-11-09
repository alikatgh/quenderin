/**
 * Named guidance, adapted from Turnstone 1.9 skills.
 *
 * One note can be active. The user selects it by name. Nothing is applied by
 * similarity, and a note cannot choose a model, temperature, or tool grant.
 * `{{model}}` is filled by the shell from the conversation's selected model
 * label. Any other `{{...}}` is left as written.
 */

export const GUIDANCE_NAME_MESSAGE = 'Guidance names are 1-48 letters, digits, spaces, or hyphens.';
export const GUIDANCE_TEXT_MESSAGE = 'Guidance text must be 1-1500 characters.';
export const GUIDANCE_CAPACITY_MESSAGE = 'The guidance notebook already holds 24 notes. Remove one before saving another.';

export type GuidanceResult = { ok: true } | { ok: false; message: string };

export function guidanceUnknownMessage(name: string): string {
    return `No guidance named "${name}". Choose a saved note by its exact name.`;
}

export function fillModelPlaceholder(text: string, modelLabel: string): string {
    const label = modelLabel.trim().slice(0, 80);
    return text.replaceAll('{{model}}', label);
}

export function guidanceBody(name: string, text: string, modelLabel: string): string {
    return `Guidance note "${name}" (instructions only; it does not change the model or which tools can run):\n${fillModelPlaceholder(text, modelLabel)}`;
}

export function appendGuidance(base: string, rendered: string | null): string {
    if (!rendered) return base;
    if (!base) return rendered;
    return `${base}\n\n${rendered}`;
}

export class GuidanceNotebook {
    static readonly MAX_NOTES = 24;
    private readonly notes = new Map<string, string>();
    private activeName: string | null = null;

    get active(): string | null {
        return this.activeName;
    }

    save(name: string, text: string): GuidanceResult {
        const cleanedName = normalizeName(name);
        if (!cleanedName) return { ok: false, message: GUIDANCE_NAME_MESSAGE };
        const cleanedText = normalizeText(text);
        if (!cleanedText) return { ok: false, message: GUIDANCE_TEXT_MESSAGE };
        if (!this.notes.has(cleanedName) && this.notes.size >= GuidanceNotebook.MAX_NOTES) {
            return { ok: false, message: GUIDANCE_CAPACITY_MESSAGE };
        }
        this.notes.set(cleanedName, cleanedText);
        return { ok: true };
    }

    /** Activate a saved note. Does not create one, and does not search by similarity. */
    select(name: string): GuidanceResult {
        const cleanedName = normalizeName(name);
        if (!cleanedName || !this.notes.has(cleanedName)) {
            return { ok: false, message: guidanceUnknownMessage(cleanedName || name.trim()) };
        }
        this.activeName = cleanedName;
        return { ok: true };
    }

    clear(): void {
        this.activeName = null;
    }

    render(modelLabel: string): string | null {
        if (!this.activeName) return null;
        const text = this.notes.get(this.activeName);
        if (!text) return null;
        return guidanceBody(this.activeName, text, modelLabel);
    }
}

function normalizeName(name: string): string | null {
    const trimmed = name.trim();
    if (trimmed.length < 1 || trimmed.length > 48) return null;
    if (!/^[A-Za-z0-9][A-Za-z0-9 -]*$/.test(trimmed)) return null;
    if (trimmed.endsWith(' ')) return null;
    return trimmed;
}

function normalizeText(text: string): string | null {
    const trimmed = text.trim();
    if (trimmed.length < 1 || trimmed.length > 1500) return null;
    for (const char of trimmed) {
        const code = char.charCodeAt(0);
        if (code < 32 && char !== '\n') return null;
    }
    return trimmed;
}
