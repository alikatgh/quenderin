import { spawn } from 'node:child_process';
import { dirname } from 'node:path';
import { performance } from 'node:perf_hooks';

export function processEnvironment() {
  return { PATH: `${dirname(process.execPath)}:/usr/bin:/bin`, LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8', TZ: 'UTC', CI: 'true' };
}

export function runtimeEnvironment(scratch, source, facts) {
  if (![scratch, source, facts].every(value => typeof value === 'string' && value.startsWith('/'))) throw new Error('Absolute fixture paths required');
  return {
    ...processEnvironment(), GITHUB_ACTIONS: 'true',
    DSH_HOME: scratch, TMPDIR: scratch,
    QUENDERIN_FIXTURE_ROOT: scratch, QUENDERIN_HOST_SOURCE: source, QUENDERIN_FIXTURE_FACTS: facts,
  };
}

/** Bound a POSIX process group, including descendants that ignore SIGTERM.
 * Descendants that deliberately create another session/group need OS isolation;
 * this helper is not an adversarial cgroup/process sandbox.
 */
export function boundedProcess(command, args, { cwd, env, timeoutMs, graceMs = 250, maxOutputBytes = 1_048_576 }) {
  if (process.platform === 'win32' || !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 180_000
      || !Number.isInteger(graceMs) || graceMs < 1 || graceMs > 1000 || !Number.isInteger(maxOutputBytes) || maxOutputBytes < 1) {
    throw new Error('Invalid bounded process configuration');
  }
  const started = performance.now();
  return new Promise(resolve => {
    const output = { stdout: [], stderr: [] };
    let size = 0, timedOut = false, outputExceeded = false, settled = false, terminating = false;
    let code = null, signal = null, error;
    let deadline, escalation, finalDeadline;
    const child = spawn(command, args, { cwd, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    const groupSignal = value => {
      if (!child.pid) return;
      try { process.kill(-child.pid, value); }
      catch (failure) { if (failure.code !== 'ESRCH') error ??= new Error('Owned process group termination failed'); }
    };
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(deadline); clearTimeout(escalation); clearTimeout(finalDeadline);
      // A successful leader must not leave group-owned workers behind.
      groupSignal('SIGKILL');
      child.stdout?.destroy(); child.stderr?.destroy(); child.unref();
      resolve({ code, signal, error, timedOut, outputExceeded, stdout: Buffer.concat(output.stdout), stderr: Buffer.concat(output.stderr), elapsedMs: performance.now() - started });
    };
    const terminate = () => {
      if (terminating || settled) return;
      terminating = true;
      groupSignal('SIGTERM');
      escalation = setTimeout(() => {
        groupSignal('SIGKILL');
        // Closing inherited pipes prevents an escaped writer retaining this
        // supervisor indefinitely. Such escape is outside the group guarantee.
        finalDeadline = setTimeout(finish, 100);
      }, graceMs);
    };
    for (const stream of ['stdout', 'stderr']) {
      child[stream].on('data', chunk => {
        const remaining = Math.max(0, maxOutputBytes - size);
        if (remaining) output[stream].push(Buffer.from(chunk.subarray(0, remaining)));
        size += chunk.length;
        if (size > maxOutputBytes) { outputExceeded = true; terminate(); }
      });
    }
    child.on('error', failure => { error = failure; finish(); });
    child.on('exit', (value, reason) => { code = value; signal = reason; terminate(); });
    child.on('close', (value, reason) => { code = value; signal = reason; finish(); });
    deadline = setTimeout(() => { timedOut = true; terminate(); }, timeoutMs);
  });
}
