---
name: solidcraft-modeling
description: Use when building a new part, enclosure, bracket, plate, flange or any other 3D solid in SolidCraft through its MCP server (tools such as batch, execute, measure, screenshot), or when a SolidCraft session is using many tool calls or tokens.
---

# SolidCraft modeling

## Overview
Work the part out as numbers first. Then build it in a few large `batch` calls, and check each stage with `measure` against values you computed yourself. A clean build takes 3-4 build batches, about 10-13 calls with the checks. Command shapes, plane axes, ids, reply sizes and known traps are in `reference.md` next to this file, so you do not need to explore the command catalog.

## Before the first call
1. Read `reference.md`.
2. Run `inspect_design {"measure":false,"sketches":false}`, even when you think the session is empty.
   - The SolidCraft server's instructions end with `Backend: connected to the SolidCraft app` when it drives the user's open app, and with `Backend: headless` otherwise.
   - If the design has timeline features, ask before calling `new_design` or `open`, because both discard unsaved work. You can also build into the open design.
3. Write a plan:
   - the parameters
   - the placement: centre the part on the origin so patterns and mirrors can work from the planes
   - every feature, with the world point you will use for each edge or face pick
   - the expected volume and bounding box

## Build
- **Stages:** use one batch per stage:
  1. parameters, sketch, dimensions, finish and the first feature
  2. fillets and shell
  3. holes, cuts and patterns
- **Failures:** a batch is all-or-nothing. On failure, read `failed.index` and `failed.error`, fix that step only, and send the batch again.
- **Risky steps:** put a risky step in a batch of its own, so a failure does not roll back the work around it. This covers booleans between curved faces that touch, and anything you have not done before.
- **Reply size:** in large designs, pass `"verbose": false` to `batch` and `execute`.
- **Sketch ids are predictable,** so later steps in the same batch can use them:
  - Each sketch counts each kind from 1 (`l1`, `c1`, `a1`, `p1`).
  - Count what the earlier steps of that sketch created. For example, `rectangle.center` makes `l1`-`l6` and `p1`-`p5`.
  - Do not split a batch just to read ids back.
- **Positions that must follow a parameter** come from:
  - sketch dimensions to `"origin"` with expression values (`"w/2 - wall - 6"`)
  - expression fields such as `solid.cylinder base:["w/2-6","d/2-6","wall"]`

  A plain number never follows a parameter.
- **Repeats:** `solid.pattern.rectangular` takes expression spacing; `solid.mirror` takes `XY`/`XZ`/`YZ`, a construction plane or `{origin, normal}`. A mirror or pattern feature cannot be mirrored or patterned again.
- **Edge and face picks** snap to the nearest edge or face. There is no distance limit and no error, so compute the exact midpoint from your geometry (the vertical corner edge of a centred box is `[w/2, d/2, h/2]`).
  - Picks must be plain numbers.
  - A pick is resolved once and then follows its edge when parameters change.
- **Profiles:** extrude takes every region by default. For a ring or a boss with a hole, pass `profiles`.
- **Order:** fillet the outside edges before you shell, so the shell follows the fillets. An edge of the face the shell removes, such as the rim of an open box, is the exception: round it after the shell, because the shell can fail on it.

## Verify
- **Each stage:** run `measure {}` (about 1 KB) and compare the volume, bbox and face count with your numbers. A cut or hole that leaves the volume unchanged has missed, even though it reported success.
- **Timeline health:** `inspect_design {"measure":false,"sketches":false}` shows each feature's `error` and `warning`.
- **Parameter test:** run `set_parameter`. Expect `errors: []`, then `measure` again; the COM and bbox should move by the amounts you computed.
- **Positions:** `measure` does not say where a feature sits. `round_faces {"body":"Body1"}` does, for everything round: each hole, boss, fillet, cone, sphere and torus comes back with its radius or diameter and the axis through it, in a few hundred bytes.
  - A bolt circle of 6 × Ø6.6 reads as six cylinders whose axes sit at the circle radius; a shelled box shows its inside corners at R - wall.
  - Compare those axes with the coordinates you computed yourself. That is the check a picture used to make.
  - On an asymmetric part, the COM shift is a second, cheaper check.
  - `body_topology` is a last resort for what is not round: it costs 25-45 KB and splits cylinders into half faces.
- **Final look, for the user rather than for you:** the checks above already prove the part, so take a picture when the user asks to see it, not to verify. `screenshot {"source":"model","view":"iso","width":480,"height":320}`, or `"view":"top"` for features inside walls, which the iso view hides.
  - An MCP reply is capped (20 KB by default: `GROK_MAX_MCP_OUTPUT_BYTES`, `[mcp] max_output_bytes`), and a render is 90-300 KB, so the image arrives cut and is dropped. Pass `path` in a folder the server allows and read the PNG from disk, or skip the picture.
  - `width` and `height` apply only to model renders.
  - When the server is bridged, `source` defaults to the whole app window and `view` also turns the user's camera, so pass `"source":"model"` and leave out `view` unless the user wants the camera moved.

## Finish
`export {path}` writes `.step` for CAD, `.3mf`/`.stl` for printing, or `.urdf` (an assembly with joints, for robot simulators). `save {path}` writes `.solidcraft`.

## Red flags

| Thought | Do instead |
|---|---|
| "List all commands first" | `reference.md`, or `list_commands {"filter":"<distinctive word>"}`. The unfiltered list is over 100 KB. |
| "Check positions with body_topology" | `round_faces` axes against your numbers. |
| "Inspect the sketch" | `sketch.solve` returns dof and the profile count in under 100 bytes. Run `sketch.inspect` on its own, never inside a big batch. |
| "new_design for a clean start" | When the server is bridged, ask first. |
| "It reported ok, so it worked" | Only a `measure` that matches the computed values counts. |
