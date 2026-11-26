
package game

import "core:testing"
import "../mission"
import "../geom"

// End-to-end mission flow, driven through game_update with synthetic Input:
// objective interaction, extraction gating, success, frozen world, restart.
//
// Shared layout: player spawns at (10, 20) on open ground; extraction is a
// radius-3 zone at (30, 20), 20 units east of the spawn.

@(test)
test_interact_out_of_range_does_not_complete_objective :: proc(t: ^testing.T) {
    world := world_init(mission.Mission{
        player_spawn = {10, 20},
        objective = {id = "documents", x = 30, y = 20},
        extraction = {x = 60, y = 20, radius = 3},
    })
    defer world_destroy(&world)

    testing.expect(t, !world.objective_complete)

    update(&world, Input{interact = true}, 0.05)

    testing.expect(t, !world.objective_complete)
    testing.expect(t, world.outcome == .PLAYING)
}

@(test)
test_interact_in_range_completes_objective_only_when_pressed :: proc(t: ^testing.T) {
    world := world_init(mission.Mission{
        player_spawn = {10, 20},
        objective = {id = "documents", x = 12, y = 20},
        extraction = {x = 60, y = 20, radius = 3},
    })
    defer world_destroy(&world)

    // Standing next to the objective is not enough without interacting.
    update(&world, Input{}, 0.05)
    testing.expect(t, !world.objective_complete)

    update(&world, Input{interact = true}, 0.05)
    testing.expect(t, world.objective_complete)
    testing.expect(t, world.outcome == .PLAYING)
}

@(test)
test_extraction_does_not_succeed_before_objective_is_complete :: proc(t: ^testing.T) {
    // Spawn inside the extraction zone with the objective out of reach.
    world := world_init(mission.Mission{
        player_spawn = {30, 20},
        objective = {id = "documents", x = 12, y = 20},
        extraction = {x = 30, y = 20, radius = 3},
    })
    defer world_destroy(&world)

    for _ in 0..<10 {
        update(&world, Input{}, 0.05)
    }

    testing.expect(t, !world.objective_complete)
    testing.expect(t, world.outcome == .PLAYING)
}

@(test)
test_mission_without_objective_can_extract_immediately :: proc(t: ^testing.T) {
    world := world_init(mission.Mission{
        player_spawn = {30, 20},
        extraction = {x = 30, y = 20, radius = 3},
    })
    defer world_destroy(&world)

    testing.expect(t, world.objective_complete)

    update(&world, Input{}, 0.05)

    testing.expect(t, world.outcome == .SUCCESS)
}

@(test)
test_complete_objective_then_walk_to_extraction_succeeds_and_freezes_world :: proc(t: ^testing.T) {
    world := world_init(mission.Mission{
        player_spawn = {10, 20},
        objective = {id = "documents", x = 12, y = 20},
        extraction = {x = 30, y = 20, radius = 3},
    })
    defer world_destroy(&world)

    update(&world, Input{interact = true}, 0.05)
    testing.expect(t, world.objective_complete)
    testing.expect(t, world.outcome == .PLAYING)

    // Walk east for up to 3 seconds; success must arrive on the way.
    for _ in 0..<60 {
        if world.outcome != .PLAYING {
            break
        }
        update(&world, Input{move = {1, 0}}, 0.05)
    }

    testing.expect(t, world.outcome == .SUCCESS)
    // Success triggers on entering the zone (x >= 27), not far beyond it.
    testing.expect(t, world.player.position.x > 26.9)
    testing.expect(t, world.player.position.x < 30)

    // The world is frozen once the mission has an outcome.
    frozen_x := world.player.position.x
    update(&world, Input{move = {1, 0}}, 0.05)
    testing.expect(t, world.player.position.x == frozen_x)
    testing.expect(t, world.outcome == .SUCCESS)
}

@(test)
test_restart_after_success_returns_to_clean_initial_state :: proc(t: ^testing.T) {
    // Parked well off the player's route along y = 20: more than the
    // footstep noise radius away, and never close enough to touch.
    patrol := []geom.Point{{20, 40}}
    guard_defs := []mission.Guard_Def{
        {id = "guard", patrol = patrol},
    }

    world := world_init(mission.Mission{
        player_spawn = {10, 20},
        objective = {id = "documents", x = 12, y = 20},
        extraction = {x = 30, y = 20, radius = 3},
        guards = guard_defs,
    })
    defer world_destroy(&world)

    update(&world, Input{interact = true}, 0.05)
    for _ in 0..<60 {
        if world.outcome != .PLAYING {
            break
        }
        update(&world, Input{move = {1, 0}}, 0.05)
    }
    testing.expect(t, world.outcome == .SUCCESS)

    // Dirty the guard so a reset has something to undo.
    world.guards[0].position = {50, 50}
    world.guards[0].awareness.state = .ALERTED

    update(&world, Input{restart = true}, 0.05)

    testing.expect(t, world.outcome == .PLAYING)
    testing.expect(t, !world.objective_complete)

    testing.expect(t, world.player.position.x == 10)
    testing.expect(t, world.player.position.y == 20)
    testing.expect(t, world.player.velocity.x == 0)
    testing.expect(t, world.player.velocity.y == 0)

    testing.expect(t, len(world.guards) == 1)
    testing.expect(t, world.guards[0].position.x == 20)
    testing.expect(t, world.guards[0].position.y == 40)
    testing.expect(t, world.guards[0].awareness.state == .UNAWARE)

    // And the mission is playable again from the clean state.
    update(&world, Input{interact = true}, 0.05)
    testing.expect(t, world.objective_complete)
}
