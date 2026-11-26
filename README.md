# Operation Eagle Nest — Greybox v0.1

A small, deliberately readable infiltration sandbox for the Commandos-inspired prototype.

**Last reviewed:** 2026-11-23
**Repository:** algo-boyz/commandos
**Branch:** main
**Engine/language:** Raylib + Odin
**Stage:** Greybox systems prototype; preparing the first playable mission

## Current baseline

- A data-driven greybox mission with a 100 × 100 top-down coordinate space.
- Mission geometry for buildings, walls/openings and cover objects.
- Shared mission collision queries used by movement and navigation.
- Player movement and guard patrol behaviour.
- Guard vision with range, field-of-view and geometry occlusion.
- Sound events with distance-based intensity and hearing thresholds.
- Guard awareness states: UNAWARE, SUSPICIOUS, ALERTED and RECOVERING.
- Last-known-position tracking with sight taking priority over sound.
- Guard investigation, search pauses/scanning and return-to-patrol behaviour.
- Grid-based A* navigation with obstacle avoidance and diagonal corner-cut prevention.
- Regression coverage for pursuit steering, pursuit around obstacles, patrol/recovery navigation and the recent moving-target jitter issue.
- A headless simulation entry point: `update(world, input, dt)`. `Input` is a plain struct filled from the keyboard in `main.odin`, and `World` owns the mission, player, guards and mission progress, so the whole simulation runs without raylib input.
- The documents objective: modelled in mission data, completed by pressing E within `OBJECTIVE_INTERACT_RADIUS` of it.
- Extraction gated on the objective, a success outcome that freezes the world, and restart (R) via `world_reset`.
- Failure: any guard touching the player (overlapping circles) ends the mission as `FAILED`, whatever the guard's awareness state. The world freezes until restart.
- Greybox feedback: objective marker, locked/unlocked extraction pad, objective status text and a mission-complete banner.
- Rendering is separated from the simulation. `render.odin` (3D scene) and `hud.odin` (2D overlay) read a `World` by value and draw from the baked collision geometry, so a wall opening you can see is one the guards and player can use, for walls of either orientation. `main.odin` is only the window, camera, input and frame loop. Raylib is imported only by `main.odin`, `render.odin`, `hud.odin` and the `isometric` package.

The README's original first-implementation checklist is therefore historical, not a list of work that is still wholly outstanding.

## Test coverage already present

| Test file | Existing coverage |
|---|---|
| guards_test.odin | Patrol and investigation movement, collision avoidance, arrival at last-known position, searching/scanning, recovery and patrol resumption, reacquisition, hearing, sight-over-sound priority, obstacle routing, unreachable targets, direct pursuit, moving-target jitter regression |
| awareness_test.odin | Initial state, suspicion accumulation/decay, alert persistence, sound suspicion, visual override, sound suspicion persistence during investigation |
| perception_test.odin | Vision range, field of view, building occlusion, wall openings |
| sound_test.odin | Noise intensity falloff, radius limits, hearing thresholds and invalid noise |
| navigation_test.odin | Direct paths, building avoidance, diagonal corner rules, blocked goals and out-of-bounds positions |
| game_test.odin | Pipeline through `game_update` with synthetic input: footsteps heard without line of sight, sneaking quieter than walking, sight building suspicion into an alert, player input stopped by geometry |
| mission_flow_test.odin | Objective interaction range and edge-triggering, extraction gating, missions without an objective, success and frozen world, restart returning to a clean state |
| mission_failure_test.odin | A guard touching the player fails the mission, the exact touch distance, failure winning over extraction in the same frame, frozen world, restart after failure, and a full see-alert-chase-catch pipeline |
| mission_reachability_test.odin | Loads the real `mission/eagle/mission.json` and checks, with the guards' own A*, that a position within `OBJECTIVE_INTERACT_RADIUS` of the objective and a position inside the extraction zone are both reachable from the spawn. |

Do not add duplicate tests for these behaviours without first identifying a specific uncovered case. Prefer strengthening an existing regression test or adding an integration test that covers a real gap.

## Important implementation notes

- mission.odin currently models player spawn, extraction location/radius, the documents objective, buildings, walls, cover and guard patrol definitions.
- `mission.json` also contains `routes`, which the runtime Mission structure does not model. Treat them as design notes, not an implemented gameplay system.
- Building interiors are solid boxes in the greybox, so the documents objective (inside the barracks) is reached from the building's outer face. `OBJECTIVE_INTERACT_RADIUS` is sized for that; revisit it if buildings gain walkable interiors.
- A mission with no objective (empty id) has extraction available from the start.
- Being caught is checked before the objective and extraction in `mission_progress_update`, so a guard touching the player on the same frame they reach extraction is a failure. Tests that walk the player across a map must keep guards off the route.
- The guard tests exercise AI functions and update behaviour directly. `game_test.odin` and `mission_flow_test.odin` cover the pipeline and mission flow through `game_update` with synthetic input on small hand-built missions; `mission_reachability_test.odin` covers the real `mission.json`, but only for reachability, not for a full playthrough.
- Within one `game_update`, a heard footstep turns the guard towards the noise before the perception pass runs. A guard with a clear view of the player can therefore hear, turn and see in the same frame, and sight then replaces the sound as the last-known source.
- The current jitter regression checks moving-target pursuit over time and caps coarse direction changes at 80 over 400 updates. It is useful coverage, but the threshold is permissive and should be treated as a regression guard, not proof of perfect pursuit.
- Navigation is a 100 × 100 grid A* implementation. Its current open-set selection scans the grid; optimise only if profiling shows it is a real bottleneck. `navigation_bench_test.odin` is the measuring tool: it does nothing in a normal `odin test .`, and `odin test . -o:speed -define:NAV_BENCH=true -define:ODIN_TEST_NAMES=main.bench_navigation -define:ODIN_TEST_THREADS=1` logs timings for a long route, a short patrol leg, an empty map, an unreachable goal and a burst of guards replanning in one frame. Record the numbers here once they have been run.
- Everything is still one Odin package (`main`). Splitting into `sim/`, `nav/`, `mission/` and `render/` directories is deferred: it needs exported names and moved tests, and is better done with a compiler in the loop than in one large patch.
- Keep gameplay geometry authoritative and independent of rendering. Gaussian splatting and production art remain later visual milestones, not prerequisites for the first playable mission.

## What is not yet a complete playable mission

The objective, extraction gating, success outcome and restart are implemented (see the baseline above). What remains:

1. Playable feedback — the greybox HUD shows objective status and the outcome, but not guard awareness beyond sphere colour.
2. Manual playthrough — the objective, extraction, failure and restart loop is covered by tests but has not yet been played through in a running build.
3. Failure tuning — touching is currently instant failure, so patrol routes and guard speed decide how forgiving the mission is. Judge that in a playthrough before changing the rule.

These are the priorities for the first playable mission. New AI features, Gaussian rendering, character animation, inventory, multiple commandos and a mission editor should not displace this milestone unless they are required to make the core loop playable.

## Recommended next milestone: first playable mission

Build the smallest complete loop using the existing greybox:

1. Load the current mission and spawn the player and guards.
2. Allow the player to infiltrate while guards patrol, perceive, investigate and recover.
3. Reach and interact with the documents objective.
4. Mark the objective complete and enable extraction.
5. Reach the extraction zone and trigger mission success.
6. Allow restart so the mission can be replayed.

### Acceptance criteria

- The mission can be started from a clean launch.
- The objective is visible/readable and can be completed through player interaction.
- Extraction cannot complete before the objective is complete.
- Entering extraction after objective completion produces a clear success state.
- Restart returns the mission to a clean initial state.
- Existing guard, awareness, perception, sound and navigation tests continue to pass.
- New tests cover objective interaction, progression gating, extraction and restart.

## Working agreements for future development

- Work from the current main state unless a different branch is explicitly agreed.
- Inspect the current implementation and tests before proposing new tests or changing behaviour.
- Avoid duplicating existing coverage; identify the precise missing behaviour first.
- Make one focused change at a time, run odin test ., and report the actual result.
- Keep patches aligned with the current source files; do not assume an older file layout or enum/state model.
- Preserve the separation between mission/gameplay geometry and rendering.
- Update this document when a milestone materially changes what is implemented or what remains.

## Source of truth

The code and tests on the reviewed branch are authoritative. The README describes the mission concept; Roadmap.md describes longer-term direction; this file records the current implementation baseline and the immediate next milestone.