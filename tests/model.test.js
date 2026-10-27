// Run with: node tests/model.test.js
const assert = require("assert")
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const ctx = {}
vm.createContext(ctx)
vm.runInContext(fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8"), ctx)

// Objects built inside the vm context have their own prototypes, so compare
// through JSON instead of deepStrictEqual.
const same = (actual, expected) => assert.strictEqual(JSON.stringify(actual), JSON.stringify(expected))

const raw = [
  "@@SELF 999",
  "@@PROCS",
  "  100     1  500000 brave",
  "  101   100  300000 brave",
  "  102   101  200000 brave",
  "  200     1  100000 bash",
  "  201   200   90000 node-MainThread",
  "  202   200   80000 node-MainThread",
  "  999   200    3000 bash",
  " 1000   999    2000 ps",
  "  300     1  900000 Hyprland",
  "  400     1    1000 Isolated Web Co",
  "@@ARGS",
  "  201 node server-a.js",
  "  202 node server-b.js",
  "@@WINDOWS",
  JSON.stringify([
    { pid: 100, class: "Brave-browser", title: "Tab" },
    { pid: 300, class: "hyprland-share-picker", title: "y" }
  ])
].join("\n")

const rows = ctx.buildRows(raw, 50)

// Helpers fold into the app's main process; protected processes never show.
same(rows.windows.map((r) => [r.pid, r.count, r.rssKiB, r.name]), [[100, 3, 1000000, "Brave-browser"]])
assert.strictEqual(rows.windows[0].detail, "Tab")

// Separate servers stay separate; the collector itself is filtered out;
// tiny processes fall under the memory threshold.
same(rows.processes.map((r) => r.pid), [200, 201, 202])
assert.strictEqual(rows.processes[1].name, "node")
assert.strictEqual(rows.processes[1].detail, "node server-a.js")

assert.strictEqual(ctx.isProtected("Hyprland"), true)
assert.strictEqual(ctx.isProtected("quickshell"), true)
assert.strictEqual(ctx.isProtected("pipewire-pulse"), true)
assert.strictEqual(ctx.isProtected("brave"), false)

const prev = [{ pid: 3 }, { pid: 1 }, { pid: 2 }]
const next = [{ pid: 1 }, { pid: 4 }, { pid: 2 }]
same(ctx.keepOrder(prev, next).map((r) => r.pid), [1, 2, 4])
same(ctx.keepOrder([], next).map((r) => r.pid), [1, 4, 2])
assert.strictEqual(ctx.sameLayout(prev, prev.slice()), true)
assert.strictEqual(ctx.sameLayout(prev, next), false)

assert.strictEqual(ctx.formatMemory(1536 * 1024), "1.5 GB")
assert.strictEqual(ctx.formatMemory(300 * 1024), "300 MB")
assert.strictEqual(ctx.rowDetail({ pid: 7, count: 3, detail: "x" }), "PID 7 · 3 procs · x")
assert.strictEqual(ctx.clampIndex(5, 3), 2)
assert.strictEqual(ctx.clampIndex(0, 0), -1)

console.log("model tests: OK")
