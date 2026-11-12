import json, os, re, sys, collections

root = os.path.expanduser("~/.config/ghostty-agents")
status = os.path.join(root, "status")
UUID = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")

def rd(p):
    with open(p, "rb") as f:
        return f.read()

cfg = json.loads(rd(os.path.join(root, "agents.json")))
print("schemaVersion", cfg.get("schemaVersion"))
projects = cfg["projects"]
print("projects", len(projects))
tasks_per = [len(p.get("tasks", [])) for p in projects]
print("tasks per project (sorted)", sorted(tasks_per), "total", sum(tasks_per))
empty_tasks = sum(1 for p in projects for t in p.get("tasks", []) if not t.get("agents"))
print("empty tasks", empty_tasks)
agents = [(p, t, a) for p in projects for t in p.get("tasks", []) for a in t.get("agents", [])]
print("agents", len(agents))
print("string agents", sum(1 for _, _, a in agents if isinstance(a, str)))
prov = collections.Counter(a.get("provider", "<absent>") for _, _, a in agents)
print("providers", dict(prov))
modes = collections.Counter(a.get("launchProfile", {}).get("startMode", "<absent>") for _, _, a in agents)
print("startModes", dict(modes))
print("with model", sum(1 for _, _, a in agents if a.get("launchProfile", {}).get("modelID")))
print("with effort", sum(1 for _, _, a in agents if a.get("launchProfile", {}).get("reasoningEffort")))
ids = [a["id"].upper() for _, _, a in agents]
print("dup ids", len(ids) - len(set(ids)))
print("projects without workingDirectory", sum(1 for p in projects if not p.get("workingDirectory")))
# key sets
print("project keys", sorted({k for p in projects for k in p}))
print("task keys", sorted({k for p in projects for t in p.get("tasks", []) for k in t}))
print("agent keys", sorted({k for _, _, a in agents for k in a}))
print("launchProfile keys", sorted({k for _, _, a in agents for k in a.get("launchProfile", {})}))

# collisions after flatten (case-insensitive within project)
groups = 0; members = 0; exact_dupes = 0
same_task_ci = 0
for p in projects:
    c = collections.defaultdict(list)
    for t in p.get("tasks", []):
        for a in t.get("agents", []):
            c[a["name"].casefold()].append((t["name"], a["name"]))
    for k, v in c.items():
        if len(v) > 1:
            groups += 1; members += len(v)
            if len({n for _, n in v}) < len(v):
                exact_dupes += 1
print("collision groups", groups, "members", members, "groups with exact-case duplicates", exact_dupes)
# localizedCaseInsensitiveCompare is close to casefold; also check task+agent rename leaves collisions
for p in projects:
    names = collections.Counter()
    for t in p.get("tasks", []):
        for a in t.get("agents", []):
            names[a["name"].casefold()] += 1
# rename rule from groundwork: keep first, rename others "<name> (<task>)"
renames = 0; post = 0
for p in projects:
    seen = set(); out = []
    flat = [(t["name"], a["name"]) for t in p.get("tasks", []) for a in t.get("agents", [])]
    allnames = {n.casefold() for _, n in flat}
    for tn, n in flat:
        if n.casefold() in seen:
            cand = f"{n} ({tn})"; i = 2
            while cand.casefold() in seen or cand.casefold() in allnames:
                cand = f"{n} ({tn}) {i}"; i += 1
            renames += 1; seen.add(cand.casefold())
        else:
            seen.add(n.casefold())
print("flatten renames needed", renames)

# status inventory
files = os.listdir(status)
print("status files", len(files))
conf = set(ids)
kinds = collections.Counter(); orphan = collections.Counter(); uuids = set(); other = []
def kind_of(name):
    m = UUID.match(name)
    if not m:
        return None, None
    u = m.group(0).upper(); rest = name[len(m.group(0)):]
    return u, rest
for f in files:
    u, rest = kind_of(f)
    if u is None:
        other.append(f); continue
    uuids.add(u)
    kinds[rest] += 1
    if u not in conf:
        orphan[rest] += 1
print("distinct uuids", len(uuids), "configured among them", len(uuids & conf))
for k in sorted(kinds):
    print("  kind", repr(k), "total", kinds[k], "orphan", orphan[k])
print("non-uuid files", len(other))
# classify non-uuid names coarsely without printing them
nonuuid_kinds = collections.Counter()
for f in other:
    if f.startswith("clawddy-hook-") or f.endswith(".tmp"):
        nonuuid_kinds["temp-like"] += 1
    else:
        ext = f.rsplit(".", 1)[-1] if "." in f else "<none>"
        nonuuid_kinds["v1/other ." + ext] += 1
print("non-uuid kinds", dict(nonuuid_kinds))

# bindings
tagged = set(); legacy = set(); forkj = set(); bad_legacy = 0; mism = 0; gen_ok = 0; gen_none = 0
pmap = {a["id"].upper(): a.get("provider", "claudeCode") for _, _, a in agents}
for u in conf:
    pj = os.path.join(status, f"{u}.session.json")
    if os.path.exists(pj):
        try:
            b = json.loads(rd(pj)); tagged.add(u)
            if b.get("provider") != pmap[u]: mism += 1
            g = b.get("launchGeneration")
            if g: gen_ok += 1
            else: gen_none += 1
        except Exception as e:
            print("undecodable session.json")
    pl = os.path.join(status, f"{u}.session")
    if os.path.exists(pl):
        legacy.add(u)
        s = rd(pl).decode().strip()
        if not re.fullmatch(r"[A-Za-z0-9._-]+", s): bad_legacy += 1
    if os.path.exists(os.path.join(status, f"{u}.fork.json")): forkj.add(u)
print("tagged session.json (configured)", len(tagged), "provider mismatches", mism, "with generation", gen_ok, "without", gen_none)
print("legacy .session (configured)", len(legacy), "legacy-only", len(legacy - tagged), "both", len(legacy & tagged), "bad legacy ids", bad_legacy)
lo = legacy - tagged
print("legacy-only providers", dict(collections.Counter(pmap[u] for u in lo)))
print("no binding at all", len(conf - tagged - legacy))
print("fork.json configured", len(forkj), "forkFrom files", sum(1 for f in files if f.endswith(".forkFrom")))

# state.json
st = json.loads(rd(os.path.join(root, "state.json")))
print("state keys", sorted(st.keys()))
def pairs(v):
    return dict(zip(v[0::2], v[1::2])) if isinstance(v, list) else v
for k in st:
    v = pairs(st[k])
    print("  state", k, len(v) if hasattr(v, "__len__") else v)
offs = pairs(st.get("eventOffsets", []))
eq = 0; ne = 0; notconf = 0
for u, o in offs.items():
    u = u.upper()
    if u not in conf: notconf += 1
    p = os.path.join(status, f"{u}.events")
    sz = os.path.getsize(p) if os.path.exists(p) else -1
    if sz == o: eq += 1
    else: ne += 1
print("offsets equal size", eq, "not equal", ne, "offsets for unconfigured", notconf)

# journals
rec = 0; untagged = 0; untagged_conf = 0; empty_provider = 0; undecodable = 0
turn_empty = 0; model_empty = 0; perm_empty = 0; events_files = 0
hook_names = collections.Counter()
for f in files:
    if not f.endswith(".events"): continue
    events_files += 1
    u = f[:-7].upper()
    for line in rd(os.path.join(status, f)).splitlines():
        if not line.strip(): continue
        rec += 1
        try:
            j = json.loads(line)
        except Exception:
            undecodable += 1; continue
        if "provider" not in j:
            untagged += 1
            if u in conf: untagged_conf += 1
        elif j.get("provider") == "":
            empty_provider += 1
        if j.get("turnID") == "": turn_empty += 1
        if j.get("model") == "": model_empty += 1
        if j.get("permissionMode") == "": perm_empty += 1
        hook_names[j.get("hookEventName") or j.get("hook_event_name")] += 1
print("journal files", events_files, "records", rec, "untagged", untagged, "untagged in configured", untagged_conf,
      "provider empty", empty_provider, "undecodable lines", undecodable)
print("turnID empty", turn_empty, "model empty", model_empty, "permissionMode empty", perm_empty)
print("hook event names", dict(hook_names))

# v1 move check: configured agents whose v1 key file exists and uuid file absent
def v1key(p, t, a):
    return re.sub(r"[^a-zA-Z0-9._-]", "_", f"{p}/{t}/{a}")
moves = 0
for p in projects:
    for t in p.get("tasks", []):
        for a in t.get("agents", []):
            k = v1key(p["name"], t["name"], a["name"])
            for ext in ["session", "session.json", "state", "heartbeat", "forkFrom", "fork.json", "lastEvent", "events", "events.lock", "json", "metadata.json"]:
                if os.path.exists(os.path.join(status, f"{k}.{ext}")) and not os.path.exists(os.path.join(status, f"{a['id'].upper()}.{ext}")):
                    moves += 1
print("v1 files that migrateStatusFiles would move", moves)

# runtime
rt = os.listdir(os.path.join(root, "runtime"))
print("runtime dirs", len(rt), "configured", sum(1 for r in rt if r.upper() in conf))
legacy_env = 0
for r in rt:
    sp = os.path.join(root, "runtime", r, "settings.json")
    if os.path.exists(sp):
        j = json.loads(rd(sp))
        if "env" in j: legacy_env += 1
print("runtime settings with env key", legacy_env)
