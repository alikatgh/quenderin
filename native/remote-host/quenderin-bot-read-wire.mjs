// JSON.parse discards whitespace and duplicate keys. Retain the literal params
// span at the plaintext decoder before parsing; old RPC methods keep their parser.
const whitespace = character => character === ' ' || character === '\n' || character === '\r' || character === '\t';
const bytes = text => new TextEncoder().encode(text).byteLength;
const skip = (text, start) => { while (whitespace(text[start])) start++; return start; };
function stringEnd(text, start) {
  for (let index = start + 1; index < text.length; index++) {
    if (text[index] === '\\') index++;
    else if (text[index] === '"') return index + 1;
  }
  throw new Error('Invalid remote JSON');
}
function valueEnd(text, start) {
  if (text[start] === '"') return stringEnd(text, start);
  if (text[start] !== '{' && text[start] !== '[') {
    let end = start;
    while (end < text.length && !whitespace(text[end]) && !',]}'.includes(text[end])) end++;
    if (end === start) throw new Error('Invalid remote JSON');
    return end;
  }
  let depth = 0;
  for (let index = start; index < text.length; index++) {
    if (text[index] === '"') index = stringEnd(text, index) - 1;
    else if (text[index] === '{' || text[index] === '[') depth++;
    else if (text[index] === '}' || text[index] === ']') { if (--depth === 0) return index + 1; }
  }
  throw new Error('Invalid remote JSON');
}
function members(text, start) {
  const result = new Map();
  let duplicate = false, index = skip(text, start);
  if (text[index++] !== '{') return { result, duplicate };
  while (index < text.length) {
    index = skip(text, index);
    if (text[index] === '}') break;
    if (text[index] !== '"') throw new Error('Invalid remote JSON');
    const end = stringEnd(text, index);
    // Long unknown keys cannot match any of the fixed route-schema keys.
    const key = end - index <= 128 ? JSON.parse(text.slice(index, end)) : text.slice(index, end);
    index = skip(text, end);
    if (text[index++] !== ':') throw new Error('Invalid remote JSON');
    const begin = skip(text, index), stop = valueEnd(text, begin);
    if (result.has(key)) duplicate = true;
    result.set(key, { begin, end: stop });
    index = skip(text, stop);
    if (text[index] === '}') break;
    if (text[index++] !== ',') throw new Error('Invalid remote JSON');
  }
  return { result, duplicate };
}
export function assertBotReadWireBytes(text) {
  if (typeof text !== 'string' || bytes(text) > 4 * 1024 * 1024) throw new Error('Remote message exceeds its bound');
  const outer = members(text, 0), payloadSpan = outer.result.get('payload');
  if (!payloadSpan) return;
  const payload = members(text, payloadSpan.begin), method = payload.result.get('method');
  if (!method || method.end - method.begin > 128 || JSON.parse(text.slice(method.begin, method.end)) !== 'plugin.route.call') return;
  const params = payload.result.get('params');
  if (!params || bytes(text.slice(params.begin, params.end)) > 4096) throw new Error('Bot roster request exceeds its bound');
  const request = members(text, params.begin), bodySpan = request.result.get('body');
  const body = bodySpan ? members(text, bodySpan.begin) : { result: new Map(), duplicate: false };
  const argsSpan = body.result.get('payload');
  const args = argsSpan ? members(text, argsSpan.begin) : { duplicate: false };
  if ([outer, payload, request, body, args].some(value => value.duplicate)) throw new Error('Duplicate Bot roster field');
}
