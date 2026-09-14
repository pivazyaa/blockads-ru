/* SPDX-License-Identifier: GPL-3.0-only
 * BlockAds RU, 2026-09-14. Reddit markers adapted from fmz200/xream.
 * No requests, storage, cookie access, logging, age-rating or subscription changes.
 */
(function () {
  "use strict";
  var reply = {};
  try { reply = transform(); } catch (_) { reply = {}; }
  $done(reply);

  function transform() {
    var url = $request.url || "";
    var service = classify(url);
    if (!service || !$response || typeof $response.body !== "string") return {};
    var status = String($response.statusCode || $response.status || "200");
    if (!/(^|\s)200(?:\s|$)/.test(status)) return {};
    var text = $response.body;
    if (!text || text.length > 1048576) return {};
    var headers = $response.headers || {};
    for (var hk in headers) {
      if (hk.toLowerCase() === "content-type" && !/^(?:application|text)\/(?:[a-z0-9.-]+\+)?json(?:\s*;|$)/i.test(String(headers[hk]))) return {};
    }
    // Most feed responses contain no ad marker. Avoid parsing and walking those.
    if (!hasAdMarker(text, service)) return {};
    var data = JSON.parse(text);
    if (!data || typeof data !== "object") return {};
    // Partial GraphQL errors are application state, not an ad-filtering target.
    if (Array.isArray(data.errors) && data.errors.length) return {};
    var state = { changed: false, work: 0, start: Date.now() };
    visit(data, service, state, 0);
    return state.changed ? { body: JSON.stringify(data) } : {};
  }

  function classify(url) {
    if (/^https:\/\/gql(?:-fed)?\.reddit\.com\/?(?:\?[^#]*)?$/.test(url)) return "reddit";
    if (/^https:\/\/oauth\.reddit\.com\/(?:r\/[^/?#]+\/)?(?:hot|new|top|best|rising|comments)(?:\/[^?#]*)?(?:\.json)?(?:\?[^#]*)?$/.test(url)) return "reddit";
    if (/^https:\/\/(?:www\.)?reddit\.com\/(?:r\/[^/?#]+\/)?(?:hot|new|top|best|rising|comments)(?:\/[^?#]*)?\.json(?:\?[^#]*)?$/.test(url)) return "reddit";
    if (/^https:\/\/www\.tiktok\.com\/api\/(?:recommend|post|mix)\/item_list\/(?:\?|$)/.test(url)) return "tiktok";
    if (/^https:\/\/(?:(?:www|m|music)\.youtube\.com|youtubei(?:-att)?\.googleapis\.com)\/youtubei\/v1\/(?:player|browse|next|search)(?:\?|$)/.test(url)) return "youtube";
    return null;
  }

  function object(x) { return x !== null && typeof x === "object" && !Array.isArray(x); }
  function populated(x) {
    if (!object(x)) return false;
    for (var k in x) if (Object.prototype.hasOwnProperty.call(x, k)) return true;
    return false;
  }

  function hasAdMarker(text, service) {
    if (service === "reddit") return /"(?:AdPost|AdMetadataCell)"|"adPayload"\s*:\s*\{|"(?:promoted|isSponsored)"\s*:\s*true|"commentsPageAds"\s*:\s*\[/.test(text);
    if (service === "tiktok") return /"isAd"\s*:\s*true/.test(text);
    return /"(?:adPlacements|adSlots|playerAds|adSlotRenderer|adPlacementRenderer|displayAdRenderer|inFeedAdLayoutRenderer|promotedSparklesWebRenderer|promotedVideoRenderer|compactPromotedVideoRenderer)"\s*:/.test(text);
  }

  function spend(state) {
    if (++state.work > 20000 || (state.work % 256 === 0 && Date.now() - state.start > 80)) throw new Error("budget");
  }

  function redditAd(item, state) {
    if (!object(item)) return false;
    var node = item.node || item.data || item;
    if (!object(node)) return false;
    if (node.__typename === "AdPost" || node.promoted === true || node.isSponsored === true) return true;
    if (populated(node.adPayload)) return true;
    if (Array.isArray(node.cells)) {
      for (var i = 0; i < node.cells.length; i++) {
        spend(state);
        if (node.cells[i] && node.cells[i].__typename === "AdMetadataCell") return true;
      }
    }
    return false;
  }

  function youtubeAd(item) {
    if (!object(item)) return false;
    var node = item.richItemRenderer && item.richItemRenderer.content || item;
    return ["adSlotRenderer", "adPlacementRenderer", "displayAdRenderer", "inFeedAdLayoutRenderer",
      "promotedSparklesWebRenderer", "promotedVideoRenderer", "compactPromotedVideoRenderer"].some(function (key) {
      return Object.prototype.hasOwnProperty.call(node, key);
    });
  }

  function visit(node, service, state, depth) {
    if (!node || typeof node !== "object") return;
    if (depth > 64) throw new Error("depth");
    spend(state);
    // Count scalar leaves too; a large flat array used to evade the work limit.
    for (var key in node) {
      if (!Object.prototype.hasOwnProperty.call(node, key)) continue;
      spend(state);
      var value = node[key];
      if (typeof value === "number" && (!isFinite(value) || (Math.floor(value) === value && Math.abs(value) > 9007199254740991))) throw new Error("unsafe integer");
      if (service === "youtube" && /^(adPlacements|adSlots|playerAds)$/.test(key) && Array.isArray(value) && value.length) {
        node[key] = []; state.changed = true; continue;
      }
      if (service === "reddit" && key === "commentsPageAds" && Array.isArray(value) && value.length) {
        node[key] = []; state.changed = true; continue;
      }
      if (Array.isArray(value)) {
        var filter = null;
        if (service === "reddit" && /^(edges|children)$/.test(key)) filter = redditAd;
        if (service === "tiktok" && key === "itemList") filter = function (item) { return object(item) && item.isAd === true; };
        if (service === "youtube" && /^(contents|items)$/.test(key)) filter = youtubeAd;
        if (filter) {
          // Compact only the parsed private copy; no second full-size array.
          var write = 0, length = value.length;
          for (var read = 0; read < length; read++) {
            spend(state);
            if (!filter(value[read], state)) value[write++] = value[read];
          }
          if (write !== length) { value.length = write; state.changed = true; }
        }
      }
      visit(value, service, state, depth + 1);
    }
  }
})();
