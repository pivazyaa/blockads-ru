/* SPDX-License-Identifier: GPL-3.0-only
 * BlockAds RU, 2026-09-13. Reddit markers adapted from fmz200/xream.
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
      if (hk.toLowerCase() === "content-type" && !/json/i.test(String(headers[hk]))) return {};
    }
    var data = JSON.parse(text);
    if (!data || typeof data !== "object") return {};
    var state = { changed: false, nodes: 0, start: Date.now() };
    visit(data, service, state, 0);
    return state.changed ? { body: JSON.stringify(data) } : {};
  }

  function classify(url) {
    if (/^https:\/\/gql(?:-fed)?\.reddit\.com\/?(?:\?[^#]*)?$/.test(url)) return "reddit";
    if (/^https:\/\/(?:www\.|oauth\.)?reddit\.com\/(?:r\/[^/?#]+\/)?(?:hot|new|top|best|rising|comments)(?:\/|\.json(?:\?|$))/.test(url)) return "reddit";
    if (/^https:\/\/(?:api\.)?(?:x|twitter)\.com\/(?:i\/api\/)?graphql\/[^/?#]+\/(?:HomeTimeline|HomeLatestTimeline|TweetDetail|SearchTimeline|UserTweets|UserTweetsAndReplies)(?:\?|$)/.test(url)) return "x";
    if (/^https:\/\/www\.tiktok\.com\/api\/(?:recommend|post|mix)\/item_list\/(?:\?|$)/.test(url)) return "tiktok";
    if (/^https:\/\/(?:(?:www|m|music)\.youtube\.com|youtubei(?:-att)?\.googleapis\.com)\/youtubei\/v1\/(?:player|browse|next|search)(?:\?|$)/.test(url)) return "youtube";
    return null;
  }

  function object(x) { return x !== null && typeof x === "object" && !Array.isArray(x); }
  function populated(x) { return object(x) && Object.keys(x).length !== 0; }

  function redditAd(item) {
    if (!object(item)) return false;
    var node = item.node || item.data || item;
    if (!object(node)) return false;
    if (node.__typename === "AdPost" || node.promoted === true || node.isSponsored === true) return true;
    if (populated(node.adPayload)) return true;
    return Array.isArray(node.cells) && node.cells.some(function (c) { return c && c.__typename === "AdMetadataCell"; });
  }

  function xAd(item) {
    if (!object(item)) return false;
    if (typeof item.entryId === "string" && /^promoted-/.test(item.entryId)) return true;
    var content = item.content || item;
    var cell = content.itemContent || (content.item && content.item.itemContent) || item.itemContent;
    if (!object(cell)) return false;
    if (populated(cell.promotedMetadata)) return true;
    var tweet = cell.tweet_results && cell.tweet_results.result;
    return object(tweet) && populated(tweet.promotedMetadata);
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
    if (++state.nodes > 20000 || depth > 64 || (state.nodes % 256 === 0 && Date.now() - state.start > 80)) throw new Error("budget");
    var keys = Object.keys(node);
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i], value = node[key];
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
        if (service === "x" && /^(entries|items)$/.test(key)) filter = xAd;
        if (service === "tiktok" && key === "itemList") filter = function (item) { return object(item) && item.isAd === true; };
        if (service === "youtube" && /^(contents|items)$/.test(key)) filter = youtubeAd;
        if (filter) {
          var clean = value.filter(function (item) { return !filter(item); });
          if (clean.length !== value.length) { node[key] = clean; value = clean; state.changed = true; }
        }
      }
      visit(value, service, state, depth + 1);
    }
  }
})();
