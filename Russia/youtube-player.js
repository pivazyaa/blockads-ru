/* SPDX-License-Identifier: GPL-3.0-only
 * BlockAds RU, 2026-09-13. Minimal YouTube player protobuf filter.
 * Field schema: Maasea/sgmodule 65075cdb388fc5e3094afd7e7314c67b243f3525.
 * Player fields 7 = adPlacements and 68 = adSlots, both length-delimited.
 * get_watch envelope path: Watch.contents (1), Content.player (2).
 * Unknown fields are copied byte-for-byte. No playback, PIP, caption or account changes.
 */
(function () {
  "use strict";
  var reply = {};
  try { reply = transform(); } catch (_) { reply = {}; }
  $done(reply);

  function transform() {
    var match = /^https:\/\/youtubei(?:-att)?\.googleapis\.com\/youtubei\/v1\/(player|get_watch)(?:\?|$)/.exec($request.url || "");
    if (!match) return {};
    var status = String($response.statusCode || $response.status || "200");
    if (!/(^|\s)200(?:\s|$)/.test(status)) return {};
    var headers = $response.headers || {}, ct = "";
    for (var k in headers) if (k.toLowerCase() === "content-type") ct = String(headers[k]);
    if (!/(?:protobuf|octet-stream)/i.test(ct)) return {};
    var source = $response.bodyBytes;
    if (!source) return {};
    var bytes = source instanceof Uint8Array ? source : new Uint8Array(source);
    if (!bytes.length || bytes.length > 2097152) return {};
    var state = { path: match[1] === "get_watch" ? [1, 2] : [], removed: 0, fields: 0, started: Date.now() };
    var result = cleanMessage(bytes, 0, state);
    return state.removed ? { body: result.buffer } : {};
  }

  function cleanMessage(bytes, level, state) {
    var cursor = { pos: 0 }, pieces = [], kept = 0, before = state.removed;
    while (cursor.pos < bytes.length) {
      if (++state.fields > 100000 || (state.fields % 512 === 0 && Date.now() - state.started > 80)) throw new Error("budget");
      var start = cursor.pos, tag = readVarint(bytes, cursor, 5);
      var field = Math.floor(tag / 8), wire = tag % 8, tagEnd = cursor.pos, payload = 0;
      if (!field || field > 536870911) throw new Error("tag");
      if (wire === 0) skipVarint(bytes, cursor);
      else if (wire === 1) cursor.pos += 8;
      else if (wire === 2) { var len = readVarint(bytes, cursor, 5); payload = cursor.pos; cursor.pos += len; }
      else if (wire === 5) cursor.pos += 4;
      else throw new Error("unsupported wire type");
      if (cursor.pos > bytes.length) throw new Error("truncated");
      if (level === state.path.length && (field === 7 || field === 68) && wire === 2) { state.removed++; continue; }
      var chunk = bytes.subarray(start, cursor.pos);
      if (level < state.path.length && field === state.path[level] && wire === 2) {
        var removedBeforeChild = state.removed;
        var child = cleanMessage(bytes.subarray(payload, cursor.pos), level + 1, state);
        if (state.removed !== removedBeforeChild) {
          var encodedLength = writeVarint(child.length), prefix = bytes.subarray(start, tagEnd);
          chunk = new Uint8Array(prefix.length + encodedLength.length + child.length);
          chunk.set(prefix); chunk.set(encodedLength, prefix.length); chunk.set(child, prefix.length + encodedLength.length);
        }
      }
      pieces.push(chunk); kept += chunk.length;
    }
    if (state.removed === before) return bytes;
    if (!kept) throw new Error("empty result");
    var result = new Uint8Array(kept), offset = 0;
    for (var i = 0; i < pieces.length; i++) { result.set(pieces[i], offset); offset += pieces[i].length; }
    return result;
  }

  function writeVarint(value) {
    var bytes = [];
    do { var b = value % 128; value = Math.floor(value / 128); bytes.push(b + (value ? 128 : 0)); } while (value);
    return new Uint8Array(bytes);
  }

  function readVarint(bytes, cursor, limit) {
    var value = 0, factor = 1;
    for (var i = 0; i < limit; i++) {
      if (cursor.pos >= bytes.length) throw new Error("truncated varint");
      var b = bytes[cursor.pos++]; value += (b & 127) * factor;
      if (b < 128) { if (value > 4294967295) throw new Error("overflow"); return value; }
      factor *= 128;
    }
    throw new Error("varint too long");
  }

  function skipVarint(bytes, cursor) {
    for (var i = 0; i < 10; i++) {
      if (cursor.pos >= bytes.length) throw new Error("truncated varint");
      var b = bytes[cursor.pos++];
      if (i === 9 && b > 1) throw new Error("overflow");
      if (b < 128) return;
    }
    throw new Error("varint too long");
  }
})();
