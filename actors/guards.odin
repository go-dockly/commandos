package actors

import "../mission"
import "../geom"
import "core:math"

// ---------------------------------------------------------------------------
// Explicit behaviour: what the guard is *doing*.
// Guard_Awareness_State remains the separate "what it knows" layer.
// ---------------------------------------------------------------------------
Guard_Behaviour :: enum u8 {
    PATROL,
    PURSUE,      // direct steering while the player is visible
    INVESTIGATE, // walking an A* path to last-known position
    SEARCH,      // scanning in place at last-known position
    RECOVER,     // returning to the nearest patrol waypoint
}

// Shared path-walking state used by patrol, investigation and recovery.
Path_Follower :: struct {
    path:  []geom.Point,
    index: int,
    ready: bool,
    found: bool,
    // Investigation tracks the integer goal cell so we can avoid
    // replanning when the target cell has not changed.
    goal_x: int,
    goal_y: int,
}

Guard_Patrol :: struct {
    points:         []geom.Point, // the authored route
    target_index:   int,
    pause_duration: f32,
    pause_remaining: f32,
    route:          Path_Follower,   // current path to the next waypoint
}

Guard_Search :: struct {
    active:            bool,
    complete:          bool,
    pause_remaining:   f32,
    base_facing:       geom.Point,
    angle:             f32,
    direction:         f32,
    sweeps_completed:  int,
}

Guard :: struct {
    id:                 string,
    position:           geom.Point,
    facing:             geom.Point,
    awareness:          Guard_Awareness,
    behaviour:          Guard_Behaviour,
    speed:              f32,
    radius:             f32,
    hearing_threshold:  f32,
    player_visible:     bool,
    pause_duration:     f32 `json:"pauseDuration"`,
    patrol:             Guard_Patrol,
    search:             Guard_Search,
    investigation:      Path_Follower,
}

GUARD_DEFAULT_SPEED :: 3.5
GUARD_DEFAULT_PAUSE :: 1.0
GUARD_RADIUS :: 0.8
GUARD_DEFAULT_HEARING_THRESHOLD :: 0.2
GUARD_SEARCH_PAUSE :: 0.75
GUARD_SEARCH_HALF_ANGLE :: 1.2217305
GUARD_SEARCH_ANGULAR_SPEED :: 1.5707963
GUARD_SEARCH_SWEEPS :: 2


// ---------------------------------------------------------------------------
// Shared movement helper
// ---------------------------------------------------------------------------

path_follower_clear :: proc(f: ^Path_Follower) {
    delete(f.path)
    f.path = nil
    f.index = 0
    f.ready = false
    f.found = false
    f.goal_x = 0
    f.goal_y = 0
}

// Attempt a single collision-checked step toward `target`.
// Returns the time consumed and whether the step was blocked.
// On success, updates guard.position and guard.facing.
guard_step_toward :: proc(
    guard: ^Guard,
    target: geom.Point,
    lvl: ^mission.Mission,
    dt: f32,
) -> (consumed: f32, blocked: bool) {
    if dt <= 0 || guard.speed <= 0 {
        return 0, false
    }

    dx := target.x - guard.position.x
    dy := target.y - guard.position.y
    distance := math.sqrt(dx*dx + dy*dy)

    if distance <= 0.0001 {
        return 0, false
    }

    step := min(guard.speed * dt, distance)
    direction := geom.Point{
        x = dx / distance,
        y = dy / distance,
    }
    candidate := geom.Point{
        x = guard.position.x + direction.x * step,
        y = guard.position.y + direction.y * step,
    }

    if mission.point_collides(lvl, candidate, guard.radius) {
        return 0, true
    }

    guard.position = candidate
    guard.facing = direction
    return step / guard.speed, false
}

// Advance the guard along the follower for up to `dt` seconds.
// Returns the unused time and whether the path was fully consumed.
// On collision the path is cleared and remaining time is returned.
follow_path :: proc(
    guard: ^Guard,
    follower: ^Path_Follower,
    lvl: ^mission.Mission,
    dt: f32,
) -> (remaining: f32, arrived: bool) {
    remaining = dt
    arrived = false

    if dt <= 0 || guard.speed <= 0 {
        return
    }

    for remaining > 0 {
        if follower.index >= len(follower.path) {
            arrived = true
            return
        }

        target := follower.path[follower.index]
        consumed, blocked := guard_step_toward(guard, target, lvl, remaining)
        if blocked {
            path_follower_clear(follower)
            return remaining, false
        }
        if consumed <= 0 {
            // Already on the waypoint (or zero-length segment).
            follower.index += 1
            continue
        }
        remaining -= consumed

        // If we covered the full distance to this waypoint, advance.
        dx := target.x - guard.position.x
        dy := target.y - guard.position.y
        if dx*dx + dy*dy <= 0.0001*0.0001 {
            follower.index += 1
        }
    }
    return
}

// ---------------------------------------------------------------------------
// Behaviour transitions
// ---------------------------------------------------------------------------

// Derive (or force) the correct behaviour from awareness + search state.
// Called at the start of each guard_update so the rest of the code can
// switch on a single enum instead of a nest of flags.
guard_sync_behaviour :: proc(guard: ^Guard) {
    if guard.awareness.state == .RECOVERING {
        guard.behaviour = .RECOVER
        return
    }

    if guard.search.active {
        guard.behaviour = .SEARCH
        return
    }

    if guard.awareness.state == .ALERTED {
        if guard.player_visible {
            guard.behaviour = .PURSUE
        } else {
            guard.behaviour = .INVESTIGATE
        }
        return
    }

    if guard.awareness.state == .SUSPICIOUS &&
       guard.awareness.last_known_source == .SOUND {
        guard.behaviour = .INVESTIGATE
        return
    }

    guard.behaviour = .PATROL
}


// ---------------------------------------------------------------------------
// Init / destroy
// ---------------------------------------------------------------------------

guards_init :: proc(lvl: ^mission.Mission) -> []Guard {
    guards := make([]Guard, len(lvl.guards), context.allocator)
    for definition, i in lvl.guards {
        speed := definition.speed
        if speed <= 0 {
            speed = GUARD_DEFAULT_SPEED
        }
        pause := definition.pause_duration
        if pause < 0 {
            pause = GUARD_DEFAULT_PAUSE
        }
        position := geom.Point{}
        if len(definition.patrol) > 0 {
            position = definition.patrol[0]
        }
        target_index := 0
        if len(definition.patrol) > 1 {
            target_index = 1
        }
        guards[i] = Guard{
            id = definition.id,
            position = position,
            facing = {1, 0},
            awareness = guard_awareness_init(),
            behaviour = .PATROL,
            speed = speed,
            radius = GUARD_RADIUS,
            hearing_threshold = GUARD_DEFAULT_HEARING_THRESHOLD,
            patrol = Guard_Patrol{
                points = definition.patrol,
                target_index = target_index,
                pause_duration = pause,
            },
        }
    }
    return guards
}

guards_destroy :: proc(guards: []Guard) {
    for guard in guards {
        delete(guard.patrol.route.path)
        delete(guard.investigation.path)
    }
    delete(guards)
}

// ---------------------------------------------------------------------------
// Hearing
// ---------------------------------------------------------------------------

guard_hear_noise :: proc(guard: ^Guard, noise: Noise_Event) {
    if guard.awareness.state == .ALERTED {
        return
    }

    if !guard_can_hear(guard.position, noise, guard.hearing_threshold) {
        return
    }

    previous_source := guard.awareness.last_known_source

    guard_awareness_hear_noise(&guard.awareness, noise.position)

    // Only face the noise if it became the active investigation target.
    if guard.awareness.last_known_source == .SOUND &&
       guard.awareness.last_known_position.x == noise.position.x &&
       guard.awareness.last_known_position.y == noise.position.y {

        dx := noise.position.x - guard.position.x
        dy := noise.position.y - guard.position.y
        direction_length := math.sqrt(dx*dx + dy*dy)

        if direction_length > 0.0001 {
            guard.facing = {
                dx / direction_length,
                dy / direction_length,
            }
        }
    }

    // A new audible event restarts an unfinished sound search.
    // A visual last-known position is never replaced by a later noise event.
    if guard.awareness.last_known_source == .SOUND &&
       (previous_source != .SOUND ||
        guard.awareness.last_known_position.x != noise.position.x ||
        guard.awareness.last_known_position.y != noise.position.y) {

        guard.search.active = false
        guard.search.complete = false
        guard.search.pause_remaining = 0
        guard.search.sweeps_completed = 0
    }
}

// ---------------------------------------------------------------------------
// Top-level update (orchestration only)
// ---------------------------------------------------------------------------

guard_update :: proc(guards: []Guard, lvl: ^mission.Mission, dt: f32) {
    if dt <= 0 {
        return
    }

    for i in 0..<len(guards) {
        guard := &guards[i]
        guard_sync_behaviour(guard)

        switch guard.behaviour {
        case .RECOVER:
            guard_recover_update(guard, lvl, dt)
        case .PURSUE, .INVESTIGATE, .SEARCH:
            guard_investigate_update(guard, lvl, dt)
        case .PATROL:
            if len(guard.patrol.points) < 2 || guard.speed <= 0 {
                continue
            }
            guard_patrol_update(guard, lvl, dt)
        }
    }
}
