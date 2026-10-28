/* Quenderin's bounded, owner-reviewed content report inbox. No payload logging. */
const QR_LIMITS = Object.freeze({
  requestBytes: 8192,
  recordBytes: 8192,
  contentBytes: 6000,
  noteBytes: 1000,
  reports: 32,
  totalRecordBytes: 262144,
  lockMilliseconds: 200
});
const QR_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const QR_SOURCES = Object.freeze(['local-chat', 'agent', 'deepseek', 'remote', 'step5']);
const QR_REASONS = Object.freeze(['harassment', 'hate', 'sexual', 'violence', 'dangerous', 'other']);

function doGet() {
  return qrJson_(qrFailure_('method_not_allowed'));
}

function doPost(event) {
  return qrJson_(qrReceive_(event, {
    lock: function () { return LockService.getScriptLock(); },
    properties: function () { return PropertiesService.getScriptProperties(); },
    uuid: function () { return Utilities.getUuid(); },
    now: function () { return new Date().toISOString(); }
  }));
}

function qrJson_(result) {
  return ContentService.createTextOutput(JSON.stringify(result))
    .setMimeType(ContentService.MimeType.JSON);
}

function qrFailure_(code) {
  return {ok: false, code: code};
}

function qrSuccess_(record) {
  return {
    ok: true,
    code: 'received',
    reportId: record.report.reportId,
    receiptId: record.receiptId,
    receivedAt: record.receivedAt
  };
}

// Counts Unicode scalar values without a blob allocation; rejects lone surrogates.
// Callers first enforce a cheap code-unit limit, including on stored values.
function qrUtf8Bytes_(value) {
  let bytes = 0;
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit < 0x80) bytes += 1;
    else if (unit < 0x800) bytes += 2;
    else if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return -1;
      index += 1;
      bytes += 4;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) return -1;
    else bytes += 3;
  }
  return bytes;
}

function qrObject_(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function qrKeys_(value, required, optional) {
  if (!qrObject_(value)) return false;
  const keys = Object.keys(value);
  return required.every(function (key) { return Object.prototype.hasOwnProperty.call(value, key); }) &&
    keys.every(function (key) { return required.indexOf(key) !== -1 || optional.indexOf(key) !== -1; });
}

function qrText_(value, maximum) {
  if (typeof value !== 'string' || value.length > maximum) return false;
  const bytes = qrUtf8Bytes_(value);
  return bytes >= 0 && bytes <= maximum;
}

function qrValidReport_(report) {
  return qrKeys_(report, ['schema', 'reportId', 'platform', 'appVersion', 'source', 'reason', 'content'], ['note']) &&
    report.schema === 1 && typeof report.reportId === 'string' && QR_UUID.test(report.reportId) &&
    report.platform === 'android' && typeof report.appVersion === 'string' &&
    /^[0-9A-Za-z][0-9A-Za-z.+_()-]{0,63}$/.test(report.appVersion) &&
    QR_SOURCES.indexOf(report.source) !== -1 && QR_REASONS.indexOf(report.reason) !== -1 &&
    qrText_(report.content, QR_LIMITS.contentBytes) && report.content.trim().length > 0 &&
    (!Object.prototype.hasOwnProperty.call(report, 'note') || qrText_(report.note, QR_LIMITS.noteBytes));
}

function qrCanonicalReport_(report) {
  return {
    schema: 1,
    reportId: report.reportId,
    platform: 'android',
    appVersion: report.appVersion,
    source: report.source,
    reason: report.reason,
    content: report.content,
    note: Object.prototype.hasOwnProperty.call(report, 'note') ? report.note : ''
  };
}

function qrCanonicalRecord_(record) {
  return {
    schema: 1,
    receiptId: record.receiptId,
    receivedAt: record.receivedAt,
    report: qrCanonicalReport_(record.report)
  };
}

function qrValidRecord_(record, reportId) {
  return qrKeys_(record, ['schema', 'receiptId', 'receivedAt', 'report'], []) && record.schema === 1 &&
    typeof record.receiptId === 'string' && QR_UUID.test(record.receiptId) &&
    typeof record.receivedAt === 'string' &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(record.receivedAt) &&
    Number.isFinite(Date.parse(record.receivedAt)) &&
    new Date(record.receivedAt).toISOString() === record.receivedAt &&
    qrValidReport_(record.report) && record.report.reportId === reportId;
}

// Reject unknown or corrupt state rather than guessing at remaining capacity.
// There is deliberately no count/index property or multi-property commit.
function qrReadInbox_(properties) {
  const values = properties.getProperties();
  if (!qrObject_(values)) return null;
  const keys = Object.keys(values);
  if (keys.length > QR_LIMITS.reports + 1) return null;
  const inbox = {enabled: false, count: 0, bytes: 0, records: Object.create(null)};
  for (let index = 0; index < keys.length; index += 1) {
    const key = keys[index];
    const value = values[key];
    if (key === 'qr.enabled') {
      if (value !== 'true' && value !== 'false') return null;
      inbox.enabled = value === 'true';
      continue;
    }
    if (key.slice(0, 7) !== 'report:' || !QR_UUID.test(key.slice(7)) ||
        typeof value !== 'string' || value.length > QR_LIMITS.recordBytes) return null;
    const bytes = qrUtf8Bytes_(value);
    if (bytes < 0 || bytes > QR_LIMITS.recordBytes) return null;
    let record;
    try { record = JSON.parse(value); } catch (_) { return null; }
    if (!qrValidRecord_(record, key.slice(7)) || JSON.stringify(qrCanonicalRecord_(record)) !== value) return null;
    inbox.records[key] = record;
    inbox.count += 1;
    inbox.bytes += bytes;
    if (inbox.count > QR_LIMITS.reports || inbox.bytes > QR_LIMITS.totalRecordBytes) return null;
  }
  return inbox;
}

function qrReceive_(event, dependencies) {
  let report;
  try {
    if (!event || !event.postData || typeof event.postData.contents !== 'string') return qrFailure_('invalid_request');
    const raw = event.postData.contents;
    // No parse, encoding pass, or service call for a definitely oversized body.
    if (raw.length > QR_LIMITS.requestBytes || event.contentLength > QR_LIMITS.requestBytes) return qrFailure_('too_large');
    if (typeof event.postData.type !== 'string' ||
        !/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(event.postData.type)) return qrFailure_('invalid_request');
    const rawBytes = qrUtf8Bytes_(raw);
    if (rawBytes < 0) return qrFailure_('invalid_request');
    if (rawBytes > QR_LIMITS.requestBytes) return qrFailure_('too_large');
    let parsed;
    try { parsed = JSON.parse(raw); } catch (_) { return qrFailure_('invalid_request'); }
    if (!qrValidReport_(parsed)) return qrFailure_('invalid_request');
    report = qrCanonicalReport_(parsed);
  } catch (_) {
    return qrFailure_('invalid_request');
  }

  let lock;
  let acquired = false;
  try {
    lock = dependencies.lock();
    acquired = lock.tryLock(QR_LIMITS.lockMilliseconds);
    if (!acquired) return qrFailure_('unavailable');
    const properties = dependencies.properties();
    const inbox = qrReadInbox_(properties);
    if (!inbox || !inbox.enabled) return qrFailure_('unavailable');
    const key = 'report:' + report.reportId;
    if (Object.prototype.hasOwnProperty.call(inbox.records, key)) {
      const existing = inbox.records[key];
      return JSON.stringify(existing.report) === JSON.stringify(report) ? qrSuccess_(existing) : qrFailure_('conflict');
    }
    if (inbox.count >= QR_LIMITS.reports) return qrFailure_('unavailable');
    const record = qrCanonicalRecord_({receiptId: dependencies.uuid(), receivedAt: dependencies.now(), report: report});
    if (!qrValidRecord_(record, report.reportId)) return qrFailure_('unavailable');
    const stored = JSON.stringify(record);
    if (stored.length > QR_LIMITS.recordBytes) return qrFailure_('too_large');
    const bytes = qrUtf8Bytes_(stored);
    if (bytes < 0 || bytes > QR_LIMITS.recordBytes) return qrFailure_('too_large');
    if (inbox.bytes + bytes > QR_LIMITS.totalRecordBytes) return qrFailure_('unavailable');
    properties.setProperty(key, stored);
    // A write may have succeeded even if the following read fails. Never undo it;
    // the same reportId and payload can reconcile on a later explicit retry.
    if (properties.getProperty(key) !== stored) return qrFailure_('unavailable');
    return qrSuccess_(record);
  } catch (_) {
    return qrFailure_('unavailable');
  } finally {
    if (acquired) {
      try { lock.releaseLock(); } catch (_) { /* Execution termination also releases it. */ }
    }
  }
}
