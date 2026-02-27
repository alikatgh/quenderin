/**
 * Production-safe logger — inspired by off-grid-mobile.
 * Suppresses all console output in production builds to prevent
 * log-injection attacks and information leakage.
 */

const isDev = process.env.NODE_ENV !== 'production';

export const logger = {
    log: (...args: unknown[]): void => {
        if (isDev) console.log(...args); // NOSONAR
    },
    warn: (...args: unknown[]): void => {
        if (isDev) console.warn(...args); // NOSONAR
    },
    error: (...args: unknown[]): void => {
        if (isDev) console.error(...args); // NOSONAR
    },
    info: (...args: unknown[]): void => {
        if (isDev) console.info(...args); // NOSONAR
    },
    /** Always log — use sparingly for critical startup/shutdown messages */
    critical: (...args: unknown[]): void => {
        console.error('[CRITICAL]', ...args); // NOSONAR
    },
};

export default logger;
