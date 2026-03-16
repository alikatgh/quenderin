/**
 * Production-safe logger with configurable verbosity.
 *
 * Log levels (set via QUENDERIN_LOG_LEVEL env var):
 *   silent  — no output at all
 *   error   — only errors and critical
 *   warn    — errors + warnings
 *   info    — errors + warnings + info/log (default in dev)
 *   debug   — everything (verbose, for debugging embedded issues)
 *
 * In production (NODE_ENV=production), defaults to 'warn'.
 * In development, defaults to 'info'.
 */

type LogLevel = 'silent' | 'error' | 'warn' | 'info' | 'debug';

const LOG_LEVEL_ORDER: Record<LogLevel, number> = {
    silent: 0,
    error: 1,
    warn: 2,
    info: 3,
    debug: 4,
};

function resolveLogLevel(): LogLevel {
    const envLevel = process.env.QUENDERIN_LOG_LEVEL?.toLowerCase() as LogLevel | undefined;
    if (envLevel && envLevel in LOG_LEVEL_ORDER) return envLevel;

    const isDev = process.env.NODE_ENV !== 'production';
    return isDev ? 'info' : 'warn';
}

const activeLevel = resolveLogLevel();
const activeLevelNum = LOG_LEVEL_ORDER[activeLevel];

function shouldLog(level: LogLevel): boolean {
    return LOG_LEVEL_ORDER[level] <= activeLevelNum;
}

export const logger = {
    log: (...args: unknown[]): void => {
        if (shouldLog('info')) console.log(...args); // NOSONAR
    },
    warn: (...args: unknown[]): void => {
        if (shouldLog('warn')) console.warn(...args); // NOSONAR
    },
    error: (...args: unknown[]): void => {
        if (shouldLog('error')) console.error(...args); // NOSONAR
    },
    info: (...args: unknown[]): void => {
        if (shouldLog('info')) console.info(...args); // NOSONAR
    },
    debug: (...args: unknown[]): void => {
        if (shouldLog('debug')) console.log('[DEBUG]', ...args); // NOSONAR
    },
    /** Always log — use sparingly for critical startup/shutdown messages */
    critical: (...args: unknown[]): void => {
        console.error('[CRITICAL]', ...args); // NOSONAR
    },
    /** The active log level, for diagnostics */
    level: activeLevel,
};

export default logger;
