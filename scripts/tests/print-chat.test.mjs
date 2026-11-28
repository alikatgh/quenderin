import assert from 'node:assert/strict';
import { Writable } from 'node:stream';
import { setImmediate } from 'node:timers/promises';
import { test } from 'node:test';
import { writePrintAnswer } from '../../src/commands/printChat.ts';

test('print output waits for a backpressured pipe through the final newline', async () => {
    const writes = [];
    let acknowledge;
    const output = new Writable({
        highWaterMark: 1,
        write(chunk, _encoding, callback) {
            writes.push(chunk.toString());
            acknowledge = callback;
        },
    });
    let finished = false;
    const pending = writePrintAnswer(output, async emit => {
        emit('first');
        emit(' second');
    }).then(() => { finished = true; });

    for (const expected of [['first'], ['first', ' second'], ['first', ' second', '\n']]) {
        await setImmediate();
        assert.deepEqual(writes, expected);
        assert.equal(finished, false);
        acknowledge();
    }
    await pending;
    assert.equal(finished, true);
});

for (const failedChunk of ['answer', '\n']) {
    test(`print output fails when ${JSON.stringify(failedChunk)} cannot be written`, async () => {
        const failure = Object.assign(new Error('closed pipe'), { code: 'EPIPE' });
        const output = new Writable({
            write(chunk, _encoding, callback) {
                callback(chunk.toString() === failedChunk ? failure : null);
            },
        });
        await assert.rejects(writePrintAnswer(output, async emit => emit('answer')), { code: 'EPIPE' });
    });
}
