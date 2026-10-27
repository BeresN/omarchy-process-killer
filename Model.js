// Session plumbing that must never be offered for killing: taking any of
// these down ends or breaks the desktop session.
var protectedNames = [
  "quickshell", "qs", "xwayland", "systemd", "(sd-pam)", "ps",
  "waitpid", "socat", "inotifywait", "wl-paste", "wl-copy",
  "dconf-service", "fcitx5", "bt-agent", "udiskie", "journalctl"
]
var protectedPrefixes = [
  "hypr", "dbus-", "pipewire", "wireplumber", "uwsm", "start-hyprland",
  "xdg-", "gnome-keyring", "at-spi", "gvfs", "omarchy-", "localsearch",
  "systemd-"
]

function isProtected(comm) {
  var name = String(comm || "").toLowerCase()
  if (protectedNames.indexOf(name) >= 0) return true
  for (var i = 0; i < protectedPrefixes.length; i++) {
    if (name.indexOf(protectedPrefixes[i]) === 0) return true
  }
  return false
}

// Raw payload sections, in order:
//   @@SELF <pid of the collecting shell>
//   @@PROCS  lines of "pid ppid rssKiB comm" (comm may contain spaces)
//   @@ARGS   lines of "pid args"
//   @@WINDOWS hyprctl clients -j
function splitSections(raw) {
  var sections = { self: -1, procs: [], args: [], windows: "" }
  var current = ""
  var windowLines = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.indexOf("@@SELF ") === 0) { sections.self = parseInt(line.substring(7), 10); continue }
    if (line === "@@PROCS" || line === "@@ARGS" || line === "@@WINDOWS") { current = line; continue }
    if (current === "@@PROCS") sections.procs.push(line)
    else if (current === "@@ARGS") sections.args.push(line)
    else if (current === "@@WINDOWS") windowLines.push(line)
  }
  sections.windows = windowLines.join("\n")
  return sections
}

function parseProcesses(sections) {
  var procs = {}
  for (var i = 0; i < sections.procs.length; i++) {
    var m = sections.procs[i].match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.+?)\s*$/)
    if (!m) continue
    var pid = parseInt(m[1], 10)
    var ppid = parseInt(m[2], 10)
    // The collector's own bash and its children (ps, hyprctl) are noise.
    if (pid === sections.self || ppid === sections.self) continue
    procs[pid] = { pid: pid, ppid: ppid, rss: parseInt(m[3], 10), comm: m[4], args: "" }
  }
  for (var j = 0; j < sections.args.length; j++) {
    var a = sections.args[j].match(/^\s*(\d+)\s+(.*)$/)
    if (a && procs[a[1]]) procs[a[1]].args = a[2].trim()
  }
  return procs
}

function parseWindows(raw) {
  try {
    var parsed = JSON.parse(String(raw || "").trim() || "[]")
    return Array.isArray(parsed) ? parsed : []
  } catch (e) {
    return []
  }
}

// An app is the largest subtree of processes sharing one name: Chromium and
// Electron helpers all descend from the main process under the same comm, so
// they fold into one row, while two separate `node` servers started from
// different shells stay apart.
function groupLeader(procs, pid, cache) {
  if (cache[pid] !== undefined) return cache[pid]
  var p = procs[pid]
  var parent = procs[p.ppid]
  var leader = parent && parent.comm === p.comm ? groupLeader(procs, parent.pid, cache) : pid
  cache[pid] = leader
  return leader
}

// The kernel cuts comm at 15 characters and some runtimes rename it
// (node-MainThread, "npm exec @wonde"); the executable reads better then.
function processName(proc) {
  var comm = proc.comm
  if (comm.length < 15 || !proc.args) return comm
  var exe = proc.args.split(/\s+/)[0]
  return exe.substring(exe.lastIndexOf("/") + 1) || comm
}

function windowName(win) {
  var cls = String(win["class"] || win.initialClass || "")
  // Reverse-DNS classes (com.mitchellh.ghostty) read best by their last part.
  var parts = cls.split(".")
  return parts[parts.length - 1] || ""
}

// Returns { windows: [...], processes: [...] }, each row:
//   { pid, name, detail, pids, count, rssKiB, hasWindow }
function buildRows(raw, minMemoryMB) {
  var sections = splitSections(raw)
  var procs = parseProcesses(sections)
  var cache = {}
  var groups = {}

  for (var key in procs) {
    var proc = procs[key]
    var leader = groupLeader(procs, proc.pid, cache)
    var group = groups[leader]
    if (!group) {
      var head = procs[leader]
      group = groups[leader] = {
        pid: leader,
        name: processName(head),
        detail: head.args,
        pids: [],
        count: 0,
        rssKiB: 0,
        hasWindow: false
      }
    }
    group.pids.push(proc.pid)
    group.count += 1
    group.rssKiB += proc.rss
  }

  var windows = parseWindows(sections.windows)
  for (var w = 0; w < windows.length; w++) {
    var win = windows[w]
    if (!procs[win.pid]) continue
    var owner = groups[groupLeader(procs, win.pid, cache)]
    if (!owner.hasWindow) {
      owner.hasWindow = true
      owner.name = windowName(win) || owner.name
      owner.detail = String(win.title || "")
    }
  }

  var minKiB = Math.max(0, Number(minMemoryMB) || 0) * 1024
  var withWindows = []
  var background = []
  for (var g in groups) {
    var row = groups[g]
    if (isProtected(procs[row.pid].comm)) continue
    if (row.hasWindow) withWindows.push(row)
    else if (row.rssKiB >= minKiB) background.push(row)
  }

  function byMemory(a, b) { return b.rssKiB - a.rssKiB }
  withWindows.sort(byMemory)
  background.sort(byMemory)
  return { windows: withWindows, processes: background }
}

// Rows keep the order they had on the previous refresh so nothing slides
// under the pointer between two clicks; newcomers join the end.
function keepOrder(previous, next) {
  var byPid = {}
  for (var i = 0; i < next.length; i++) byPid[next[i].pid] = next[i]
  var ordered = []
  for (var j = 0; j < previous.length; j++) {
    var row = byPid[previous[j].pid]
    if (!row) continue
    ordered.push(row)
    delete byPid[previous[j].pid]
  }
  for (var k = 0; k < next.length; k++) {
    if (byPid[next[k].pid]) ordered.push(next[k])
  }
  return ordered
}

function sameLayout(a, b) {
  if (a.length !== b.length) return false
  for (var i = 0; i < a.length; i++) {
    if (a[i].pid !== b[i].pid) return false
  }
  return true
}

function formatMemory(kib) {
  var mb = kib / 1024
  if (mb >= 1024) return (mb / 1024).toFixed(1) + " GB"
  return Math.round(mb) + " MB"
}

function rowDetail(row) {
  var parts = ["PID " + row.pid]
  if (row.count > 1) parts.push(row.count + " procs")
  if (row.detail) parts.push(row.detail)
  return parts.join(" · ")
}

function clampIndex(index, length) {
  if (length <= 0) return -1
  return Math.max(0, Math.min(length - 1, index))
}
