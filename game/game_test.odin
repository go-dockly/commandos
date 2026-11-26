
package game

import "core:testing"
import "../mission"
import "../geom"

// These tests drive game_update with synthetic Input, so they cover the
// player -> noise/perception -> awareness -> guard pipeline without raylib
// input. Unit-level behaviour of each stage lives in its own *_test.odin.

@(test)
test_walking_player_is_heard_by_guard_without_line_of_sight :: proc(t: ^testing.T) {
    // A building blocks sight between the player and the guard, so any
    // reaction must come from the footstep alone.
    buildings := []geom.Rect{
        {id = "blocker", x = 14, y = 15, w = 2, h = 10},
    }
    patrol := []geom.Point{{20, 20}}
    guard_defs := []mission.Guard_Def{
        {id = "guard", patrol = patrol},
    }

    world := world_init(mission.Mission{
        player_spawn = {10, 20},
        buildings = buildings,
        guards = guard_defs,
    })
    defer world_destroy(&world)

    update(&world, Input{move = {1, 0}}, 0.1)

    guard := world.guards[0]

    testing.expect(t, !guard.player_visible)
    testing.expect(t, guard.awareness.state == .SUSPICIOUS)
    testing.expect(t, guard.awareness.last_known_source == .SOUND)
    testing.expect(
        t,
        guard.awareness.last_known_position.x == world.player.position.x,
    )
    testing.expect(
        t,
        guard.awareness.last_known_position.y == world.player.position.y,
    )
}

@(test)
test_sneaking_player_is_not_heard_at_walking_distance :: proc(t: ^testing.T) {
    // Same geometry as the walking test: ~9.6 units is inside the walking
    // noise radius (18) but outside the sneaking radius (6).
    buildings := []geom.Rect{
        {id = "blocker", x = 14, y = 15, w = 2, h = 10},
    }
    patrol := []geom.Point{{20, 20}}
    guard_defs := []mission.Guard_Def{
        {id = "guard", patrol = patrol},
    }

    world := world_init(mission.Mission{
        player_spawn = {10, 20},
        buildings = buildings,
        guards = guard_defs,
    })
    defer world_destroy(&world)

    update(&world, Input{move = {1, 0}, sneak = true}, 0.1)

    guard := world.guards[0]

    testing.expect(t, world.player.position.x > 10)
    testing.expect(t, guard.awareness.state == .UNAWARE)
    testing.expect(t, guard.awareness.last_known_source == .NONE)
}

@(test)
test_guard_with_clear_view_builds_suspicion_then_alerts :: proc(t: ^testing.T) {
    // Guard faces +x (the default) with an unobstructed view of a
    // stationary player 10 units away.
    patrol := []geom.Point{{20, 20}}
    guard_defs := []mission.Guard_Def{
        {id = "guard", patrol = patrol},
    }

    world := world_init(mission.Mission{
        player_spawn = {30, 20},
        guards = guard_defs,
    })
    defer world_destroy(&world)

    // 0.5s of sight is less than AWARENESS_DEFAULT.build_duration (1.25s).
    for _ in 0..<5 {
        update(&world, Input{}, 0.1)
    }

    testing.expect(t, world.guards[0].player_visible)
    testing.expect(t, world.guards[0].awareness.state == .SUSPICIOUS)
    testing.expect(t, world.guards[0].awareness.last_known_source == .SIGHT)
    testing.expect(t, world.guards[0].awareness.suspicion > 0)
    testing.expect(t, world.guards[0].awareness.suspicion < 1)

    // 2.0s in total is past the build duration.
    for _ in 0..<15 {
        update(&world, Input{}, 0.1)
    }

    testing.expect(t, world.guards[0].player_visible)
    testing.expect(t, world.guards[0].awareness.state == .ALERTED)
    testing.expect(t, world.guards[0].awareness.last_known_source == .SIGHT)
}

@(test)
test_player_input_is_stopped_by_mission_geometry :: proc(t: ^testing.T) {
    buildings := []geom.Rect{
        {id = "blocker", x = 14, y = 15, w = 2, h = 10},
    }

    world := world_init(mission.Mission{
        player_spawn = {10, 20},
        buildings = buildings,
    })
    defer world_destroy(&world)

    // Hold right for 3 seconds: plenty of time to reach and push on the wall.
    for _ in 0..<60 {
        update(&world, Input{move = {1, 0}}, 0.05)
    }

    wall_face := f32(14) - world.player.radius

    testing.expect(t, world.player.position.x > 12.5)
    testing.expect(t, world.player.position.x < wall_face + 0.001)
}
