#!/usr/bin/env python3
import argparse, json, os, sys, time, urllib.parse, urllib.request, random

def api(server, path, data=None, timeout=20):
    url = f"{server}{path}"
    if data is not None:
        data = json.dumps(data).encode()
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    else:
        req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def list_workflows(server):
    return api(server, "/userdata?dir=workflows&recurse=true&split=false")

def pick_template(server, workflow, match_ckpt):
    """Find the most recent /history API-format prompt matching the target graph.

    We reuse a previously-executed API prompt because /prompt requires API format,
    while the saved .json is UI format. Match heuristics identify the right graph.
    """
    hist = api(server, "/history?max_items=200")
    entries = list(hist.items())  # insertion order = chronological; last = newest
    # signatures keyed by known workflow name
    sig = {
        "HighRes_live": lambda cls: "IPAdapterUnifiedLoader" in cls and "CheckpointLoaderSimple" in cls,
        "Qwen_Live":    lambda cls: "UNETLoader" in cls and "ModelSamplingAuraFlow" in cls,
    }
    want = sig.get(workflow)
    best = None
    for k, v in entries:
        p = v.get("prompt", [])
        if len(p) < 3:
            continue
        graph = p[2]
        cls = {n.get("class_type") for n in graph.values()}
        if want and not want(cls):
            continue
        if match_ckpt:
            cks = [n["inputs"].get("ckpt_name") for n in graph.values()
                   if n.get("class_type") == "CheckpointLoaderSimple"]
            if match_ckpt not in cks:
                continue
        best = (k, graph)
    return best

def find_prompt_nodes(graph):
    """Return (positive_id, negative_id) by tracing the base KSampler (denoise==1.0)."""
    samplers = [(i, n) for i, n in graph.items()
                if n.get("class_type") in ("KSampler", "KSamplerAdvanced")]
    base = None
    for i, n in samplers:
        if abs(float(n["inputs"].get("denoise", 1.0)) - 1.0) < 1e-6:
            base = (i, n); break
    if base is None and samplers:
        base = samplers[0]
    if base is None:
        return None, None
    _, n = base
    def enc(link):
        return link[0] if isinstance(link, list) else None
    pos, neg = enc(n["inputs"].get("positive")), enc(n["inputs"].get("negative"))
    # Follow through until we land on a CLIPTextEncode-like node
    def resolve_text(nid, depth=0):
        if nid is None or depth > 4:
            return nid
        node = graph.get(nid, {})
        if "text" in node.get("inputs", {}) and isinstance(node["inputs"]["text"], str):
            return nid
        for v in node.get("inputs", {}).values():
            if isinstance(v, list):
                r = resolve_text(v[0], depth + 1)
                if r and "text" in graph.get(r, {}).get("inputs", {}):
                    return r
        return nid
    return resolve_text(pos), resolve_text(neg)

def find_detailer_nodes(graph):
    """Return a list of detailer descriptors, each tracing its own pos/neg text node.

    Covers FaceDetailer / DetailerForEach* nodes that carry direct positive and
    negative conditioning links to CLIPTextEncode nodes. Region intent (face, eyes,
    hands, ...) lives in each detailer's own prompt, so they are edited individually.
    """
    def link(v):
        return v[0] if isinstance(v, list) else None
    def resolve_text(nid, depth=0):
        if nid is None or depth > 4:
            return None
        node = graph.get(nid, {})
        if isinstance(node.get("inputs", {}).get("text"), str):
            return nid
        for v in node.get("inputs", {}).values():
            if isinstance(v, list):
                r = resolve_text(v[0], depth + 1)
                if r is not None:
                    return r
        return None
    out = []
    for i, n in graph.items():
        ct = n.get("class_type", "")
        ins = n.get("inputs", {})
        if "Detailer" in ct and isinstance(ins.get("positive"), list):
            pid = resolve_text(link(ins.get("positive")))
            nid = resolve_text(link(ins.get("negative")))
            out.append({
                "detailer": i, "class_type": ct,
                "positive_node": pid,
                "positive_text": graph.get(pid, {}).get("inputs", {}).get("text") if pid else None,
                "negative_node": nid,
                "negative_text": graph.get(nid, {}).get("inputs", {}).get("text") if nid else None,
            })
    out.sort(key=lambda d: int(d["detailer"]) if d["detailer"].isdigit() else 0)
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default="http://127.0.0.1:8188")
    ap.add_argument("--workflow", default="HighRes_live")
    ap.add_argument("--match-ckpt", default=None, help="require this checkpoint in the template")
    ap.add_argument("--set-ckpt", default=None, help="override the checkpoint (ckpt_name) in the graph in-memory")
    ap.add_argument("--positive", default=None)
    ap.add_argument("--negative", default=None)
    ap.add_argument("--left", default=None, help="regional prompt for the LEFT subject (needs --right)")
    ap.add_argument("--right", default=None, help="regional prompt for the RIGHT subject (needs --left)")
    ap.add_argument("--common", default=None, help="shared full-canvas prompt in regional mode (default: --positive)")
    ap.add_argument("--region-width", type=float, default=0.75,
                    help="width fraction of each side's region; higher = more center overlap = more cohesion (default 0.75)")
    ap.add_argument("--list-detailers", action="store_true",
                    help="print each detailer's current positive/negative text as JSON, then exit")
    ap.add_argument("--detailers-json", default=None,
                    help='JSON dict {detailerNodeId: {"positive": "...", "negative": "..."}} to edit per-region detailer prompts')
    ap.add_argument("--batch", type=int, default=None)
    ap.add_argument("--seed", type=int, default=None, help="fixed seed (default: randomize)")
    ap.add_argument("--outdir", default="/tmp/comfy_out")
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    picked = pick_template(args.server, args.workflow, args.match_ckpt)
    if not picked:
        print(f"ERROR: no /history template found for workflow '{args.workflow}'. "
              f"Run it once in the ComfyUI UI first so an API-format prompt exists.", file=sys.stderr)
        sys.exit(2)
    tmpl_id, graph = picked

    if args.list_detailers:
        print(json.dumps(find_detailer_nodes(graph), indent=2))
        return

    if args.positive is None:
        print("ERROR: --positive is required (unless --list-detailers).", file=sys.stderr)
        sys.exit(6)

    pos_id, neg_id = find_prompt_nodes(graph)
    if not pos_id:
        print("ERROR: could not locate positive prompt node.", file=sys.stderr)
        sys.exit(3)

    graph[pos_id]["inputs"]["text"] = args.positive
    if args.negative is not None and neg_id:
        graph[neg_id]["inputs"]["text"] = args.negative

    if args.left and args.right:
        clip_link = graph[pos_id]["inputs"].get("clip")
        graph[pos_id]["inputs"]["text"] = args.common if args.common is not None else args.positive
        def enc(nid, text):
            graph[nid] = {"class_type": "CLIPTextEncode", "inputs": {"text": text, "clip": clip_link}}
        def area(nid, cond, x, w):
            graph[nid] = {"class_type": "ConditioningSetAreaPercentage",
                          "inputs": {"conditioning": [cond, 0], "width": w, "height": 1.0,
                                     "x": x, "y": 0.0, "strength": 1.0}}
        def combine(nid, a, b):
            graph[nid] = {"class_type": "ConditioningCombine",
                          "inputs": {"conditioning_1": [a, 0], "conditioning_2": [b, 0]}}
        w = max(0.5, min(1.0, args.region_width))
        enc("rp_left_txt", args.left)
        enc("rp_right_txt", args.right)
        area("rp_left_area", "rp_left_txt", 0.0, w)
        area("rp_right_area", "rp_right_txt", round(1.0 - w, 3), w)
        combine("rp_c1", "rp_left_area", "rp_right_area")
        combine("rp_c2", "rp_c1", pos_id)
        for i, n in graph.items():
            if n.get("class_type") in ("KSampler", "KSamplerAdvanced") and isinstance(n["inputs"].get("positive"), list):
                n["inputs"]["positive"] = ["rp_c2", 0]
        print(f"regional: left 0-{int(w*100)}%% | right {int((1-w)*100)}-100%%, overlap {int((2*w-1)*100)}%%, shared prompt full-canvas")

    if args.set_ckpt:
        swapped = [i for i, n in graph.items()
                   if n.get("class_type") == "CheckpointLoaderSimple"]
        for i in swapped:
            graph[i]["inputs"]["ckpt_name"] = args.set_ckpt
        print(f"checkpoint -> {args.set_ckpt} (nodes {swapped})")

    if args.detailers_json:
        edits = json.loads(args.detailers_json)
        det = {d["detailer"]: d for d in find_detailer_nodes(graph)}
        for did, spec in edits.items():
            d = det.get(str(did))
            if not d:
                print(f"WARN: detailer node {did} not found; skipping.", file=sys.stderr); continue
            if spec.get("positive") is not None and d["positive_node"]:
                graph[d["positive_node"]]["inputs"]["text"] = spec["positive"]
            if spec.get("negative") is not None and d["negative_node"]:
                graph[d["negative_node"]]["inputs"]["text"] = spec["negative"]
            print(f"detailer {did}: pos_node={d['positive_node']} neg_node={d['negative_node']} updated")
    for i, n in graph.items():
        if n.get("class_type") in ("KSampler", "KSamplerAdvanced"):
            n["inputs"]["seed" if "seed" in n["inputs"] else "noise_seed"] = \
                args.seed if args.seed is not None else random.randint(1, 2**48)
    if args.batch is not None:
        for n in graph.values():
            if n.get("class_type") in ("EmptyLatentImage", "EmptySD3LatentImage"):
                n["inputs"]["batch_size"] = args.batch

    print(f"template={tmpl_id[:8]} positive_node={pos_id} negative_node={neg_id}")
    print(f"positive: {args.positive}")
    if args.dry_run:
        print("(dry-run: not queued)"); return

    resp = api(args.server, "/prompt", {"prompt": graph})
    if resp.get("node_errors"):
        print("NODE ERRORS:", json.dumps(resp["node_errors"])); sys.exit(4)
    pid = resp["prompt_id"]
    print(f"queued prompt_id={pid}")

    deadline = time.time() + args.timeout
    while time.time() < deadline:
        h = api(args.server, f"/history/{pid}")
        if h:
            break
        time.sleep(5)
    else:
        print("ERROR: timed out waiting for completion.", file=sys.stderr); sys.exit(5)

    os.makedirs(args.outdir, exist_ok=True)
    outs = h[pid]["outputs"]
    saved = []
    for _, o in outs.items():
        for im in o.get("images", []):
            if im.get("type") != "output":
                continue
            q = urllib.parse.urlencode({"filename": im["filename"],
                                        "subfolder": im.get("subfolder", ""), "type": im["type"]})
            fn = os.path.join(args.outdir, im["filename"])
            urllib.request.urlretrieve(f"{args.server}/view?{q}", fn)
            saved.append(fn)
    print(f"done, {len(saved)} image(s):")
    for f in saved:
        print(f)

if __name__ == "__main__":
    main()
