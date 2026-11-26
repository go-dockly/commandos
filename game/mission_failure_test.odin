
package game

import "core:testing"
import "../mission"
import "../geom"

// Failure: any guard touching the player ends the mission. Touching means the
// guard and player circles overlap (guard radius + player radius = 1.6 with
// the default sizes), whatever the guard's awareness state.

@(test)
test_guard_touching_player_fails_the_mission :: proc(t: ^testing.T) {
    // A stationary, unaware guard 0.5 units from the player is touching.
    patrol := []geom.Point{{10.5, 20}}
    guard_defs := []mission.Guard_Def{
        {id = "guard", patrol = patrol},
    }

    world := world_init(mission.Mission{
        player_spawn = {10, 20},
        guards = guard_defs,
    })
    defer world_destroy(&world)

    testing.expect(t, world.outcome == .PLAYING)

    update(&world, Input{}, 0.05)

    testing.expect(t, world.outcome == .FAILED)
}

@(test)
test_guard_just_outside_touch_distance_does_not_fail_the_mission :: proc(t: ^testing.T) {
    // Combined radii are 1.6. At 1.7 the circles do not overlap; at 1.5
    // they do. The guard faces away (default +x), so it neither sees nor
    // hears the stationary player and stays put.
    far_patrol := []geom.Point{{11.7, 20}}
    far_defs := []mission.Guard_Def{
        {id = "far", patrol = far_patrol},
    }
    far_world := world_init(mission.Mission{
        player_spawn = {10, 20},
        guards = far_defs,
    })
    defer world_destroy(&far_world)

    for _ in 0..<10 {
        update(&far_world, Input{}, 0.05)
    }
    testing.expect(t, far_world.outcome == .PLAYING)

    near_patrol := []geom.Point{{11.5, 20}}
    near_defs := []mission.Guard_Def{
        {id = "near", patrol = near_patrol},
    }
    near_world := world_init(mission.Mission{
        player_spawn = {10, 20},
        guards = near_defs,
    })
    defer world_destroy(&near_world)

    update(&near_world, Input{}, 0.05)
    testing.expect(t, near_world.outcome == .FAILED)
}

@(test)
test_being_caught_at_extraction_is_a_failure_not_a_success :: proc(t: ^testing.T) {
    // No objective, so extraction is available immediately and the player is
    // standing in the zone. A guard touching them in the same frame wins.
    patrol := []geom.Point{{30.5, 20}}
    guard_defs := []mission.Guard_Def{
        {id = "guard", patrol = patrol},
    }

    world := world_init(mission.Mission{
        player_spawn = {30, 20},
        extraction = {x = 30, y = 20, radius = 3},
        guards = guard_defs,
    })
    defer world_destroy(&world)

    update(&world, Input{}, 0.05)

    testing.expect(t, world.outcome == .FAILED)

    // The world is frozen once failed.
    frozen_x := world.player.position.x
    update(&world, Input{move = {1, 0}}, 0.05)
    testing.expect(t, world.player.position.x == frozen_x)
    testing.expect(t, world.outcome == .FAILED)
}

@(test)
test_restart_after_failure_returns_to_clean_initial_state :: proc(t: ^testing.T) {
    patrol := []geom.Point{{10.5, 20}}
    guard_defs := []mission.Guard_Def{
        {id = "guard", patrol = patrol},
    }

    world := world_init(mission.Mission{
        player_spawn = {10, 20},
        objective = {id = "documents", x = 12, y = 20},
        guards = guard_defs,
    })
    defer world_destroy(&world)

    update(&world, Input{}, 0.05)
    testing.expect(t, world.outcome == .FAILED)

    update(&world, Input{restart = true}, 0.05)

    testing.expect(t, world.outcome == .PLAYING)
    testing.expect(t, !world.objective_complete)
    testing.expect(t, world.player.position.x == 10)
    testing.expect(t, world.player.position.y == 20)
    testing.expect(t, len(world.guards) == 1)
    testing.expect(t, world.guards[0].position.x == 10.5)
    testing.expect(t, world.guards[0].position.y == 20)
    testing.expect(t, world.guards[0].awareness.state == .UNAWARE)
}

@(test)
test_alerted_guard_chases_stationary_player_until_it_catches_them :: proc(t: ^testing.T) {
    // Full pipeline: the guard sees the player, builds suspicion, alerts,
    // pursues in a straight line and touches them. The player never moves.
    patrol := []geom.Point{{20, 20}}
    guard_defs := []mission.Guard_Def{
        {id = "guard", patrol = patrol},
    }

    world := world_init(mission.Mission{
        player_spawn = {30, 20},
        guards = guard_defs,
    })
    defer world_destroy(&world)

    frames := 0
    for _ in 0..<160 {
        if world.outcome != .PLAYING {
            break
        }
        update(&world, Input{}, 0.05)
        frames += 1
    }

    testing.expect(t, world.outcome == .FAILED)
    testing.expect(t, world.guards[0].awareness.state == .ALERTED)
    // Suspicion takes over a second to build before the chase begins, so
    // the catch cannot be instant.
    testing.expect(t, frames > 20)
    testing.expect(t, world.player.position.x == 30)
}
