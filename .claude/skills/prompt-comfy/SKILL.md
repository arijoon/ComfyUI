---
name: prompt-comfy
description: Generate an image via the locally-running ComfyUI server (default :8188) by reusing a saved workflow's graph and swapping in a new prompt. Trigger when the user says "prompt comfy" or asks to generate/run something in ComfyUI.
user-invocable: true
---

# prompt-comfy

Queue an image generation on the local ComfyUI server without touching the user's
saved workflow `.json` files.

## How it works

ComfyUI's `/prompt` endpoint needs the **API format** graph, while saved workflows are
**UI format**. Rather than convert, the helper reuses a previously-executed API-format
graph from the server's `/history`, edits only the prompt text + seeds in memory, and
POSTs the whole graph. Saved workflow files are never modified.

Requirement: the target workflow must have been run at least once in the ComfyUI UI so a
history entry exists. If not, tell the user to run it once first.

## Steps

1. Confirm the server is up: `curl -s -m3 http://127.0.0.1:8188/system_stats | head -c1`.
   If nothing, tell the user to start ComfyUI.

2. Pick the workflow. Default is `HighRes_live` (SDXL + IPAdapter, hires-fix,
   FaceDetailer chain). `Qwen_Live` is the fast Qwen-Image lightning graph.
   List saved ones with `curl -s "http://127.0.0.1:8188/userdata?dir=workflows&recurse=true&split=false"`.

3. Build the positive prompt from the user's request. Keep the workflow's existing
   negative unless the user asks to change it (pass `--negative`).

4. **Update the detailer prompts too.** `HighRes_live` runs a chain of region-specific
   `FaceDetailer` nodes, each with its own positive/negative prompt. These are not copies
   of the base prompt. When the new request changes an attribute that a detailer's prompt
   also specifies, update that detailer so it doesn't contradict the base prompt.

   **Only four detailers are enabled — edit ONLY these:**

   | Region | Detailer node |
   |--------|---------------|
   | face   | 21 |
   | hands  | 24 |
   | eyes   | 30 |
   | lips   | 31 |

   The rest (jewelry `32`, empty `39`/`44`/`49`) are disabled — leave them alone.
   `--list-detailers` still shows all of them; only pass edits for 21/24/30/31.
   First list them, then pass edits as JSON keyed by detailer node id:

```bash
python3 .claude/skills/prompt-comfy/comfy_prompt.py --workflow HighRes_live --list-detailers
```

5. Run the helper:

```bash
python3 .claude/skills/prompt-comfy/comfy_prompt.py \
  --workflow HighRes_live \
  --positive "<positive prompt>" \
  --detailers-json '{"<detailer id>":{"positive":"<region prompt>"}}' \
  --outdir /tmp/comfy_out
```

   Useful flags: `--negative "..."`, `--detailers-json '{...}'`, `--list-detailers`,
   `--batch N`, `--seed N` (default randomizes),
   `--match-ckpt <checkpoint.safetensors>` to force a specific template variant,
   `--set-ckpt <checkpoint.safetensors>` to swap the model in-memory (does NOT need a
   history entry for that checkpoint — overrides every `CheckpointLoaderSimple`),
   `--dry-run` to preview which nodes get edited without queueing.

   To try a different model, list installed checkpoints with
   `curl -s http://127.0.0.1:8188/object_info/CheckpointLoaderSimple | python3 -c "import sys,json;print('\n'.join(json.load(sys.stdin)['CheckpointLoaderSimple']['input']['required']['ckpt_name'][0]))"`
   then pass one to `--set-ckpt`. Stick to the template's model family so the
   IPAdapter/detailer chain stays compatible.

6. The helper prints the output image paths and queues the job. **Do NOT read, open, or
   display the result images in any way** — only the user reviews outputs. Report that the
   job is queued/done and the output paths, then wait for the user to come back with any
   changes.

## Rules

- **Never save/modify workflow `.json` files.** The helper only reads `/history` and
  POSTs an in-memory graph to `/prompt`; keep it that way. Do not write to `userdata`.
- **Never look at the result images.** Do not Read, view, or display any output image.
  Only the user reviews generations; report queued/done status and paths, then wait.

## Notes

- The helper auto-locates the base positive/negative nodes by tracing the base KSampler
  (denoise==1.0), and detailer prompt nodes by tracing each `FaceDetailer`'s own
  positive/negative links — so it survives graph edits with no hardcoded node IDs.
- It reuses the **most recent** matching history graph, so it inherits whatever
  checkpoint / LoRAs / IPAdapter face references were used last. If the user wants a
  different checkpoint or face reference, note that history reuse carries those over;
  use `--match-ckpt` or edit the graph further.
