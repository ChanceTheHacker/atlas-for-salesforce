import test from "node:test";
import assert from "node:assert/strict";
import {cachedResearch, invalidateResearch, researchScope} from "../salesforce/force-app/main/default/lwc/atlasLib/cache.js";
import {historyQueue} from "../salesforce/force-app/main/default/lwc/atlasLib/history.js";

function storage() {
  const old = globalThis.sessionStorage, values = new Map();
  globalThis.sessionStorage = {getItem: (k) => values.get(k) || null, setItem: (k, v) => values.set(k, v), removeItem: (k) => values.delete(k)};
  return {values, restore: () => { globalThis.sessionStorage = old; }};
}
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => {resolve = yes; reject = no;}); return {promise, resolve, reject}; };

test("research cache scopes users/orgs, canonicalizes keys and preserves literal query text", async () => {
  let calls = 0;
  const fetch = async () => ({count: ++calls});
  const request = {id: "one", op: "soql", query: "SELECT Id FROM Account WHERE Name = 'a  b'"};
  const first = await cachedResearch("org:user", request, fetch);
  const second = await cachedResearch("org:user", {query: request.query, op: "soql", id: "two"}, fetch);
  assert.equal(second.cache.hit, true); assert.equal(calls, 1);
  second.result.count = 99;
  assert.equal((await cachedResearch("org:user", request, fetch)).result.count, first.result.count);
  await cachedResearch("org:user2", request, fetch); await cachedResearch("org2:user", request, fetch);
  await cachedResearch("org:user", {...request, query: request.query.replace("a  b", "a b")}, fetch);
  assert.equal(calls, 4);
  assert.equal(researchScope({org:{id:"org"}}), null);
});

test("cache coalesces in-flight reads, expires, bypasses on fresh and never caches failures", async () => {
  let time = 100000, calls = 0; const wait = deferred();
  const request = {op: "users", term: "Chris"};
  const fetch = async () => {calls++; return wait.promise;};
  const a = cachedResearch("ttl", request, fetch, () => time), b = cachedResearch("ttl", request, fetch, () => time);
  wait.resolve({name: "Chris"}); await a; assert.equal((await b).cache.hit, true); assert.equal(calls, 1);
  time += 30001;
  await cachedResearch("ttl", request, fetch, () => time); assert.equal(calls, 2);
  await cachedResearch("ttl", {...request, fresh: true}, fetch, () => time); assert.equal(calls, 3);
  invalidateResearch("ttl");
  await assert.rejects(cachedResearch("ttl", request, async () => {throw Error("denied");}), /denied/);
  assert.equal((await cachedResearch("ttl", request, fetch)).cache.hit, false);
  let rest = 0;
  await cachedResearch("ttl", {op:"rest",path:"/query/cursor"}, async () => ++rest);
  await cachedResearch("ttl", {op:"rest",path:"/query/cursor"}, async () => ++rest);
  assert.equal(rest, 2);
});

test("invalidation and newer forced reads prevent late snapshots from poisoning the cache", async () => {
  const wait = deferred(), request = {op:"describe", object:"Account"};
  const old = cachedResearch("race", request, () => wait.promise);
  invalidateResearch("race"); wait.resolve({old:true});
  await assert.rejects(old, /changed during this read/);
  const slow = deferred(); const prior = cachedResearch("race", request, () => slow.promise);
  await cachedResearch("race", {...request, fresh:true}, async () => ({new:true}));
  slow.resolve({old:true}); await prior;
  assert.deepEqual((await cachedResearch("race", request, () => assert.fail("cached expected"))).result, {new:true});
});

test("large results are usable but not retained past the cache budget", async () => {
  let calls = 0; const fetch = async () => ({body: "x".repeat(4000001), count: ++calls});
  await cachedResearch("large", {op:"retrieve"}, fetch);
  await cachedResearch("large", {op:"retrieve"}, fetch);
  assert.equal(calls, 2);
});

test("history enqueue returns before the server while ordered exact receipts persist", async () => {
  const store = storage(), wait = deferred(), calls = [];
  const key = "history-fast";
  const queue = historyQueue(key, async (batch) => { calls.push(batch); await wait.promise; return batch.map((m) => ({nonce:m.nonce,recordId:m.nonce})); });
  try {
    await queue.enqueue({direction:"From Agent",kind:"atlas-questions",body:"one"});
    await queue.enqueue({direction:"To Agent",kind:"answers",body:"two"});
    assert.equal(queue.pending.length, 2); assert.equal(JSON.parse(store.values.get(key)).length, 2);
    assert.equal(historyQueue(key, () => assert.fail("do not replace writer")), queue);
    wait.resolve(); await queue.flush();
    assert.deepEqual(calls.flat().map((m) => m.body), ["one", "two"]);
    assert.equal(store.values.has(key), false);
  } finally {store.restore();}
});

test("lost history responses retain exact retry identities and reload never reprocesses commands", async () => {
  const store = storage(); let fail = true; const calls = [];
  const write = async (batch) => {calls.push(JSON.stringify(batch)); if(fail) throw Error("response lost"); return batch.map((m) => ({nonce:m.nonce,recordId:m.nonce}));};
  const queue = historyQueue("history-retry", write);
  try {
    await queue.enqueue({direction:"From Agent",kind:"atlas-request",body:"original"});
    await assert.rejects(queue.flush(), /response lost/);
    const reloaded = await import("../salesforce/force-app/main/default/lwc/atlasLib/history.js?reload-test");
    const resumed = reloaded.historyQueue("history-retry", write);
    assert.equal(resumed.pending[0].body, "original");
    fail = false; await resumed.flush();
    assert.equal(calls[0], calls.at(-1)); assert.equal(resumed.pending.length, 0);
  } finally {store.restore();}
});

test("oversized history cannot poison the ordered outbox", async () => {
  const store = storage(), calls = [];
  const queue = historyQueue("history-oversized", async (batch) => {calls.push(...batch); return batch.map((m) => ({nonce:m.nonce,recordId:m.nonce}));});
  try {
    assert.throws(() => queue.enqueue({direction:"To Agent",kind:"results",body:"x".repeat(1500001)}), /1,500,000/);
    assert.equal(queue.pending.length, 0);
    await queue.enqueue({direction:"To Agent",kind:"results",body:"valid"});
    await queue.flush(); assert.deepEqual(calls.map((m) => m.body), ["valid"]);
  } finally {store.restore();}
});

test("enqueue during drain settlement still waits for the second server receipt without browser storage", async () => {
  const old = globalThis.sessionStorage, first = deferred(), second = deferred(), calls = [];
  globalThis.sessionStorage = {getItem: () => null, setItem: () => {throw Error("quota");}, removeItem: () => {}};
  try {
    const queue = historyQueue("history-settlement", async (batch) => {
      calls.push(batch);
      await (calls.length === 1 ? first.promise : second.promise);
      return batch.map((m) => ({nonce:m.nonce,recordId:m.nonce}));
    });
    const a = queue.enqueue({direction:"To Agent",kind:"results",body:"first"});
    await Promise.resolve(); first.resolve();
    await Promise.resolve(); await Promise.resolve();
    let done = false;
    const b = queue.enqueue({direction:"To Agent",kind:"results",body:"second"}).then(() => {done = true;});
    await a; await Promise.resolve(); await Promise.resolve();
    assert.equal(done, false); assert.equal(calls.length, 2);
    second.resolve(); await b;
    assert.deepEqual(calls.flat().map((m) => m.body), ["first", "second"]);
    assert.equal(queue.pending.length, 0);
  } finally {globalThis.sessionStorage = old;}
});

test("unavailable browser storage makes history wait for confirmed server persistence", async () => {
  const old = globalThis.sessionStorage, wait = deferred(); let done = false;
  globalThis.sessionStorage = {getItem: () => null, setItem: () => {throw Error("quota");}, removeItem: () => {}};
  try {
    const queue = historyQueue("history-no-storage", async (batch) => {await wait.promise; return batch.map((m) => ({nonce:m.nonce,recordId:m.nonce}));});
    const work = queue.enqueue({direction:"To Agent",kind:"results",body:"keep"}).then(() => {done = true;});
    await Promise.resolve(); assert.equal(done, false);
    wait.resolve(); await work; assert.equal(done, true);
  } finally {globalThis.sessionStorage = old;}
});

test("history held only in this tab is never reported as recoverable", async () => {
  const old = globalThis.sessionStorage, values = new Map(), events = [], waits = [];
  let broken = true;
  globalThis.sessionStorage = {getItem: (k) => values.get(k) ?? null, setItem: (k, v) => { if (broken) throw Error("quota"); values.set(k, v); }, removeItem: (k) => values.delete(k)};
  const write = async (batch) => { await new Promise((resolve) => waits.push(resolve)); return batch.map((m) => ({nonce: m.nonce, recordId: m.nonce})); };
  const tick = async () => { for (let i = 0; i < 5; i++) await new Promise((resolve) => setImmediate(resolve)); };
  try {
    const queue = historyQueue("history-memory-only", write);
    queue.subscribe((event) => events.push(event));
    // Each body is large enough to be saved on its own, so the queue drains in two steps.
    const big = "x".repeat(400000);
    queue.enqueue({direction: "To Agent", kind: "results", body: big + "1"}).catch(() => {});
    queue.enqueue({direction: "To Agent", kind: "results", body: big + "2"}).catch(() => {});
    assert.equal(queue.recoverable, false);
    assert.match(events.at(-1).problem, /2 message\(s\) are held only in this tab/);
    await tick(); waits.shift()(); await tick();
    // Saving the first message must not make the second look safe.
    assert.equal(queue.pending.length, 1); assert.equal(events.at(-1).recoverable, false);
    assert.match(events.at(-1).problem, /1 message\(s\) are held only in this tab/);
    waits.shift()(); await tick();
    assert.equal(queue.pending.length, 0); assert.equal(events.at(-1).recoverable, true); assert.equal(events.at(-1).problem, "");

    // Once storage works again the copy is written and the queue is recoverable.
    queue.enqueue({direction: "To Agent", kind: "results", body: "a"}).catch(() => {});
    assert.equal(queue.recoverable, false);
    await tick(); broken = false; waits.shift()(); await tick();
    const later = queue.enqueue({direction: "To Agent", kind: "results", body: "b"});
    assert.equal(queue.recoverable, true); assert.equal(JSON.parse(values.get("history-memory-only")).length, 1);
    await later; await tick(); waits.shift()(); await tick();

    // A failed save says whether the browser copy can still recover the messages.
    const failing = historyQueue("history-memory-failure", async () => { throw Error("Row lock"); });
    failing.subscribe((event) => events.push(event));
    await failing.enqueue({direction: "To Agent", kind: "results", body: "kept"});
    await tick();
    assert.equal(events.at(-1).problem, "History NOT saved: Row lock"); assert.equal(events.at(-1).recoverable, true);
    broken = true;
    await assert.rejects(failing.enqueue({direction: "To Agent", kind: "results", body: "memory"}), /Row lock/);
    assert.match(events.at(-1).problem, /^History NOT saved: Row lock 2 message\(s\) are held only in this tab/);
  } finally { globalThis.sessionStorage = old; }
});

test("an unreadable browser copy is left alone and new history waits for Salesforce", async () => {
  const old = globalThis.sessionStorage, values = new Map([["history-unreadable", "{not json"]]), events = [];
  globalThis.sessionStorage = {getItem: (k) => values.get(k) ?? null, setItem: (k, v) => values.set(k, v), removeItem: (k) => values.delete(k)};
  let release;
  try {
    const queue = historyQueue("history-unreadable", async (batch) => { await new Promise((resolve) => {release = resolve;}); return batch.map((m) => ({nonce: m.nonce, recordId: m.nonce})); });
    queue.subscribe((event) => events.push(event));
    assert.match(events[0].problem, /recovery is unavailable/);
    let done = false;
    const work = queue.enqueue({direction: "To Agent", kind: "results", body: "keep"}).then(() => {done = true;});
    assert.equal(queue.recoverable, false); assert.match(events.at(-1).problem, /held only in this tab/);
    while (!release) await new Promise((resolve) => setImmediate(resolve));
    assert.equal(done, false); release(); await work;
    assert.equal(values.get("history-unreadable"), "{not json");
  } finally { globalThis.sessionStorage = old; }
});

test("status polls start quick and back off to the cap", async () => {
  const {pollDelay} = await import("../salesforce/force-app/main/default/lwc/atlasLib/poll.js");
  assert.deepEqual([0, 1, 2, 3, 4, 5, 50].map((i) => pollDelay(i)), [500, 1000, 1500, 2000, 2500, 3000, 3000]);
  assert.deepEqual([0, 3, 9].map((i) => pollDelay(i, 2000)), [500, 2000, 2000]);
});
