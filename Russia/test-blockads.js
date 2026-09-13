/* SPDX-License-Identifier: GPL-3.0-only
 * Run: node test-blockads.js. Synthetic fixtures only; no network or account data.
 * Also runnable in a V8 harness with BLOCKADS_SCRIPTS supplied by the caller.
 */
(function () {
  "use strict";
  var sources = typeof BLOCKADS_SCRIPTS === "object" ? BLOCKADS_SCRIPTS : {
    social: require("fs").readFileSync(require("path").join(__dirname, "social-json.js"), "utf8"),
    youtube: require("fs").readFileSync(require("path").join(__dirname, "youtube-player.js"), "utf8")
  };
  var passed = [], failures = [];
  function assert(ok, message) { if (!ok) throw new Error(message || "assertion"); }
  function same(a, b) { assert(JSON.stringify(a) === JSON.stringify(b), "values differ"); }
  function test(name, fn) { try { fn(); passed.push(name); } catch (e) { failures.push({ name: name, error: String(e) }); } }
  function run(kind, url, response) {
    var calls = 0, reply;
    new Function("$request", "$response", "$done", sources[kind])({ url: url }, response, function (v) { calls++; reply = v; });
    assert(calls === 1, "$done must be called exactly once");
    return reply;
  }
  function json(url, data, headers) { return run("social", url, { status: 200, headers: headers || { "Content-Type": "application/json" }, body: JSON.stringify(data) }); }
  var reddit = "https://gql.reddit.com/";
  var x = "https://x.com/i/api/graphql/test/HomeTimeline?variables=test";
  var tik = "https://www.tiktok.com/api/recommend/item_list/?count=20";
  var yt = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false";
  var native = "https://youtubei.googleapis.com/youtubei/v1/player?alt=proto";
  test("Reddit filters explicit ad posts and preserves NSFW", function () {
    var good = { node: { __typename: "Post", id: "ok", isNsfw: true, text: "ads are a topic", adPayload: null } };
    var data = { data: { feed: { elements: { edges: [good, { node: { __typename: "AdPost" } }, { node: { cells: [{ __typename: "AdMetadataCell" }] } }, { node: { adPayload: { id: "ad" } } }] } } } };
    same(JSON.parse(json(reddit, data).body).data.feed.elements.edges, [good]);
  });
  test("Reddit null, cursors and comments survive", function () {
    var good = { node: null, cursor: "keep" };
    var data = { data: { children: { commentsPageAds: [1], comments: ["keep"] }, feed: { elements: { edges: [good] } } } };
    var out = JSON.parse(json(reddit, data).body);
    same(out.data.children, { commentsPageAds: [], comments: ["keep"] }); same(out.data.feed.elements.edges, [good]);
  });
  test("Reddit listing preserves post fields", function () {
    var good = { kind: "t3", data: { id: "normal", over_18: true, promoted: false } };
    var out = json("https://www.reddit.com/r/test/hot.json", { data: { after: "cursor", children: [good, { data: { promoted: true } }] } });
    same(JSON.parse(out.body).data, { after: "cursor", children: [good] });
  });
  test("X removes promoted entries, preserving tweets and cursors", function () {
    var good = { entryId: "tweet-1", content: { itemContent: { text: "promotedMetadata is a field" } } };
    var cursor = { entryId: "cursor-bottom", content: { value: "cursor" } };
    var data = { data: { timeline: { instructions: [{ entries: [good, cursor, { entryId: "promoted-tweet-2" }, { content: { itemContent: { promotedMetadata: { advertiser: "test" } } } }] }] } } };
    same(JSON.parse(json(x, data).body).data.timeline.instructions[0].entries, [good, cursor]);
  });
  test("TikTok only explicit isAd=true is removed", function () {
    var good = [{ id: "normal" }, { id: "false", isAd: false }, { id: "unknown", isAd: "true" }];
    same(JSON.parse(json(tik, { itemList: good.concat([{ id: "ad", isAd: true }]), cursor: "next", hasMore: true }).body), { itemList: good, cursor: "next", hasMore: true });
  });
  test("YouTube JSON preserves playback and account state", function () {
    var data = { adPlacements: [1], adSlots: [2], playerAds: [3], playabilityStatus: { status: "OK" }, streamingData: { url: "keep" }, captions: { language: "ru" }, isPremium: false };
    var out = JSON.parse(json(yt, data).body); data.adPlacements = []; data.adSlots = []; data.playerAds = []; same(out, data);
  });
  test("YouTube feed removes explicit ad renderer only", function () {
    var good = { videoRenderer: { title: "Ad blocking explained" } };
    var out = json("https://www.youtube.com/youtubei/v1/browse", { contents: [good, { richItemRenderer: { content: { adSlotRenderer: { id: 1 } } } }] });
    same(JSON.parse(out.body), { contents: [good] });
  });
  test("Unknown JSON schema passes byte-for-byte", function () { same(json(reddit, { data: { futureSchema: [1, null, "text"] } }), {}); });
  test("Malformed JSON passes unchanged", function () { same(run("social", reddit, { body: "{broken" }), {}); });
  test("HTML passes unchanged", function () { same(json(reddit, { adSlots: [1] }, { "content-type": "text/html" }), {}); });
  test("Error responses pass unchanged", function () { same(run("social", reddit, { status: 503, body: "{}" }), {}); });
  test("Unknown host is not modified", function () { same(json("https://bank.example/", { itemList: [{ isAd: true }] }), {}); });
  test("Lookalike host is not modified", function () { same(json("https://gql.reddit.com.evil.example/", { data: { children: { commentsPageAds: [1] } } }), {}); });
  test("Login and payment endpoints are not modified", function () { same(json("https://x.com/i/api/graphql/test/Login", { entries: [{ entryId: "promoted-1" }] }), {}); });
  test("Native TikTok is outside unverified MITM scope", function () { same(json("https://api16-normal-c-useast1a.tiktokv.com/aweme/v1/feed/", { itemList: [{ isAd: true }] }), {}); });
  test("Large JSON is passed through", function () { same(run("social", reddit, { body: " ".repeat(1048577) }), {}); });
  test("Deep JSON aborts all changes", function () { var v = { data: { children: { commentsPageAds: [1] } } }, p = v; for (var i = 0; i < 70; i++) { p.next = {}; p = p.next; } same(json(reddit, v), {}); });
  test("Unsafe integer IDs abort all changes", function () { same(run("social", reddit, { body: '{"data":{"children":{"commentsPageAds":[1]}},"id":9223372036854775807}' }), {}); });
  function vi(n) { var a = []; do { var b = n % 128; n = Math.floor(n / 128); a.push(b + (n ? 128 : 0)); } while (n); return a; }
  function ld(field, data) { return vi(field * 8 + 2).concat(vi(data.length), data); }
  function binary(data, url, ct) { return run("youtube", url || native, { status: 200, headers: { "Content-Type": ct || "application/x-protobuf" }, bodyBytes: new Uint8Array(data) }); }
  test("Protobuf removes fields 7 and 68, preserves all other bytes", function () {
    var retained = ld(2, [8, 1]).concat(ld(12345, [255, 0, 33]), [8, 150, 1]);
    var input = retained.concat(ld(7, [1, 2]), ld(68, [3, 4]));
    same(Array.from(new Uint8Array(binary(input).body)), retained);
  });
  test("Protobuf same field numbers with other wire types survive", function () { same(binary(vi(7*8).concat([1], vi(68*8+5), [1,2,3,4])), {}); });
  test("Protobuf nested field 7 in unknown message survives", function () { same(binary(ld(100, ld(7, [1,2,3]))), {}); });
  test("get_watch filters only the documented nested player", function () {
    var player = ld(2, [8, 1]), next = ld(3, ld(7, [5]));
    var input = ld(1, ld(2, player.concat(ld(7, [9]), ld(68,[1]))).concat(next)).concat(ld(7,[10]));
    var wanted = ld(1, ld(2, player).concat(next)).concat(ld(7,[10]));
    same(Array.from(new Uint8Array(binary(input, "https://youtubei.googleapis.com/youtubei/v1/get_watch").body)), wanted);
  });
  test("get_watch malformed known player passes entirely unchanged", function () {
    same(binary(ld(1, ld(2,[18,255])), "https://youtubei.googleapis.com/youtubei/v1/get_watch"), {});
  });
  test("Protobuf unknown 64-bit varint preserved exactly", function () {
    var kept = vi(100*8).concat([255,255,255,255,255,255,255,255,255,1]);
    same(Array.from(new Uint8Array(binary(kept.concat(ld(7, [1]))).body)), kept);
  });
  test("Protobuf truncated lengths abort all changes", function () { same(binary(ld(7,[1]).concat([18,255])), {}); });
  test("Protobuf unsupported group wire type passes unchanged", function () { same(binary([11,12]), {}); });
  test("Protobuf zero field is rejected without changes", function () { same(binary([0,0]), {}); });
  test("Protobuf all-ad result is not turned into empty response", function () { same(binary(ld(7,[1])), {}); });
  test("Protobuf JSON content type passes unchanged", function () { same(binary(ld(7,[1]), native, "application/json"), {}); });
  test("Protobuf large body passes unchanged", function () { same(binary(new Array(2097153).fill(0)), {}); });
  test("Protobuf non-player endpoint passes unchanged", function () { same(binary(ld(7,[1]), "https://youtubei.googleapis.com/youtubei/v1/browse"), {}); });
  test("Scripts contain no network, persistent state or logging APIs", function () {
    [sources.social, sources.youtube].forEach(function (s) { assert(!/\$(?:httpClient|task|persistentStore|prefs|notification)|\b(?:fetch|XMLHttpRequest|WebSocket)\s*\(|console\./.test(s), "forbidden API"); });
  });
  var bench = { fixture: "100 posts, 10 explicit Reddit ads", iterations: 100, milliseconds: 0 };
  var edges = []; for (var i = 0; i < 100; i++) edges.push({ node: { __typename: i%10 ? "Post" : "AdPost", text: "x".repeat(200) } });
  var start = Date.now(); for (var n = 0; n < bench.iterations; n++) json(reddit, { data: { feed: { elements: { edges: edges } } } });
  bench.milliseconds = Date.now() - start;
  var report = { runtime: typeof process !== "undefined" ? process.version : "V8 code-mode harness", passed: passed.length, failures: failures, tests: passed, benchmark: bench, iphone_runtime_tested: false };
  globalThis.BLOCKADS_TEST_REPORT = report;
  if (typeof module !== "undefined" && module.exports) { console.log(JSON.stringify(report, null, 2)); if (failures.length) process.exitCode = 1; }
})();
