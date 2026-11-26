
package game

import "core:mem"
import "core:testing"

import "../actors"
import "../mission"
import "../nav"
import "../geom"

// Loads the real mission.json and checks the mission is winnable on the
// actual map: from the spawn, the player can reach a spot from which the
// objective can be interacted with, and a spot inside the extraction zone.
//
// This guards against data or tuning changes (moving the objective, resizing
// OBJECTIVE_INTERACT_RADIUS, adding cover) that would silently make the first
// mission impossible. The hand-built missions in mission_flow_test.odin
// cannot catch that.

// True if some navigable cell centre within `reach` of `target` can be
// reached from `from` by an agent of `agent_radius`, using the same A*
// that the guards use.
cell_within_reach :: proc(
    level: ^mission.Mission,
    from: geom.Point,
    target: geom.Point,
    reach: f32,
    agent_radius: f32,
) -> bool {
    grid_w, grid_h := nav.nav_grid_dims(level)
    min_x := max(int(target.x - reach) - 1, 0)
    max_x := min(int(target.x + reach) + 1, grid_w - 1)
    min_y := max(int(target.y - reach) - 1, 0)
    max_y := min(int(target.y + reach) + 1, grid_h - 1)

    for y in min_y..=max_y {
        for x in min_x..=max_x {
            centre := nav.nav_cell_center(x, y)

            dx := centre.x - target.x
            dy := centre.y - target.y
            if dx*dx + dy*dy > reach*reach {
                continue
            }

            // Cells inside solid geometry are rejected immediately by
            // find_path, so only genuinely open cells cost a search.
            path := nav.find_path(level, from, centre, agent_radius)
            if path.found {
                return true
            }
        }
    }

    return false
}

@(test)
test_real_mission_objective_and_extraction_are_reachable_from_spawn :: proc(t: ^testing.T) {
    // Everything allocated while loading and searching goes into a scratch
    // arena, so the test runner's leak tracking has nothing to report.
    outer := context.allocator
    backing := make([]byte, 8 * 1024 * 1024, outer)
    defer delete(backing, outer)

    arena: mem.Arena
    mem.arena_init(&arena, backing)
    context.allocator = mem.arena_allocator(&arena)

    level, loaded := mission.load("mission/eagle/mission.json")
    testing.expect(
        t,
        loaded,
        "could not load mission.json; run the tests from the repository root",
    )
    if !loaded {
        return
    }

    player_radius := actors.player_init({}).radius

    testing.expect(t, mission_has_objective(&level))
    testing.expect(t, level.extraction.radius > 0)
    testing.expect(
        t,
        !mission.point_collides(&level, level.player_spawn, player_radius),
        "player spawn is inside solid geometry",
    )

    objective := geom.Point{level.objective.x, level.objective.y}
    extraction := geom.Point{level.extraction.x, level.extraction.y}

    testing.expect(
        t,
        cell_within_reach(
            &level,
            level.player_spawn,
            objective,
            OBJECTIVE_INTERACT_RADIUS,
            player_radius,
        ),
        "no reachable position within OBJECTIVE_INTERACT_RADIUS of the objective",
    )

    testing.expect(
        t,
        cell_within_reach(
            &level,
            level.player_spawn,
            extraction,
            level.extraction.radius,
            player_radius,
        ),
        "no reachable position inside the extraction zone",
    )
}
