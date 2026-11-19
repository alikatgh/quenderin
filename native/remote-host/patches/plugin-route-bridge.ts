import type { PluginRouteCallParams, PluginRouteCallResult } from '@dsh-remote/protocol'
import type { SafeLogger } from './logging.js'
import { RpcError } from './safe-error.js'
import { BOT_READ_LIMITS, validateBotReadRequest, validateBotReadResponse } from './quenderin-bot-read-policy.mjs'
import { BOT_WORK_LIMITS, botWorkFields, validateBotWorkRequest, validateBotWorkResponse } from './quenderin-bot-work-policy.mjs'
import type { BotWorkScope } from './quenderin-bot-work-journal.mjs'

export const PLUGIN_ROUTE_ALLOWLIST = ['api/bot'] as const
export const BOT_REMOTE_OPERATIONS = ['quenderin-roster', 'quenderin-submit', 'quenderin-command'] as const
export function isAllowedPluginRoute(route: string): route is typeof PLUGIN_ROUTE_ALLOWLIST[number] { return route === 'api/bot' }
export type PluginRouteDispatcher = ((route: string, body: unknown, signal: AbortSignal) => Promise<{ status: number; json: unknown }>) & {
  quenderinBotReadAvailable?: () => boolean
  quenderinBotWorkAvailable?: () => boolean
}
export type { BotWorkScope }
export class PluginRouteBridge {
  constructor(private readonly dispatch: PluginRouteDispatcher, private readonly logger?: SafeLogger) {}
  async call(input: unknown): Promise<PluginRouteCallResult> {
    const work = validateBotWorkRequest(input)
    let read: ReturnType<typeof validateBotReadRequest> | undefined
    if (!work.ok) {
      try {
        const outer = botWorkFields(input, ['route', 'body']), body = botWorkFields(outer.body, ['endpoint', 'payload'])
        const payload = botWorkFields(body.payload, ['schemaVersion', 'workspaceId'])
        read = validateBotReadRequest(input, payload.workspaceId)
      } catch { /* Invalid exact request. */ }
    }
    if (!work.ok && !read?.ok) throw new RpcError('INVALID_MESSAGE', 'The Bot route request is invalid.')
    const params = (work.ok ? work.value : read!.ok ? read!.value : undefined) as PluginRouteCallParams
    const startedAt = performance.now()
    let result: { status: number; json: unknown }
    try { result = await this.dispatch(params.route, params.body, AbortSignal.timeout(BOT_WORK_LIMITS.dispatchTimeoutMilliseconds)) }
    catch (error) {
      this.logger?.warn('plugin route call failed', { route: params.route, durationMs: Math.round(performance.now() - startedAt) })
      throw error
    }
    const maximum = work.ok ? BOT_WORK_LIMITS.resultUTF8Bytes : BOT_READ_LIMITS.resultUTF8Bytes
    if (new TextEncoder().encode(JSON.stringify(result)).byteLength > maximum) throw new RpcError('RESPONSE_TOO_LARGE', 'The Bot route response exceeds its bound.')
    if (result.status !== 200) return { status: 503, json: { ok: false, error: { code: work.ok ? 'BOT_WORK_UNAVAILABLE' : 'BOT_READ_UNAVAILABLE', message: 'Bot route unavailable' } } }
    const valid = work.ok ? validateBotWorkResponse(result, params) : validateBotReadResponse(result, read!.ok ? read!.value.body.payload.workspaceId : undefined)
    if (!valid.ok) throw new RpcError('INVALID_MESSAGE', 'The Bot route response is invalid.')
    return { status: result.status, json: result.json }
  }
}
