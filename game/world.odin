package game

import "../actors"
import "../geom"
import "../mission"

// Everything the simulation owns while a mission is running.
// Rendering reads from a World; it never mutates one.
World :: struct {
    level: mission.Mission,
    player: actors.Player,
    guards: []actors.Guard,
    objective_complete: bool,
    outcome: mission.Outcome,
}

mission_has_objective :: proc(level: ^mission.Mission) -> bool {
    return level.objective.id != ""
}

// Builds a World from a loaded mission. The World takes the mission by
// value; guards keep slice views into the mission's patrol data.
world_init :: proc(level: mission.Mission) -> World {
    world := World{level = level}
    world_reset(&world)
    return world
}

// Returns the world to its clean initial state. Mission data is untouched,
// so this is also the restart path.
world_reset :: proc(world: ^World) {
    actors.guards_destroy(world.guards)

    world.player = actors.player_init(world.level.player_spawn)
    world.guards = actors.guards_init(&world.level)

    // A mission without an objective never gates extraction.
    world.objective_complete = !mission_has_objective(&world.level)
    world.outcome = .PLAYING
}

world_destroy :: proc(world: ^World) {
    actors.guards_destroy(world.guards)
    geom.destroy(&world.level.geometry)
    world.guards = nil
}

// True when any guard overlaps the player. Being touched ends the mission
// whatever the guard's awareness state: an unaware patrol that walks into the
// player counts as much as an alerted pursuer.
world_player_caught :: proc(world: ^World) -> bool {
    for guard in world.guards {
        dx := guard.position.x - world.player.position.x
        dy := guard.position.y - world.player.position.y
        reach := guard.radius + world.player.radius

        if dx*dx + dy*dy <= reach*reach {
            return true
        }
    }

    return false
}

// True when the player's centre is within radius of a mission-space point.
world_player_within :: proc(world: ^World, x, y, radius: f32) -> bool {
    dx := world.player.position.x - x
    dy := world.player.position.y - y
    return dx*dx + dy*dy <= radius*radius
}
