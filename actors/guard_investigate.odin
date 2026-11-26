package actors

import "../mission"
import "../nav"
import "../geom"
import "core:math"

// ---------------------------------------------------------------------------
// Investigation path preparation
// ---------------------------------------------------------------------------

guard_investigation_path_prepare :: proc(
    guard: ^Guard,
    level: ^mission.Mission,
    target: geom.Point,
) {
    // During visible pursuit, finish the current route before
    // considering a new target position.
    if guard.player_visible && guard.investigation.ready {
        return
    }
    goal_x := int(target.x)
    goal_y := int(target.y)

    if guard.investigation.ready &&
       guard.investigation.goal_x == goal_x &&
       guard.investigation.goal_y == goal_y {
        return
    }

    path_follower_clear(&guard.investigation)

    guard.investigation.goal_x = goal_x
    guard.investigation.goal_y = goal_y
    guard.investigation.ready = true

    path := nav.find_path(
        level,
        guard.position,
        target,
        guard.radius,
    )

    guard.investigation.path = path.points
    guard.investigation.index = 0
    guard.investigation.found = path.found
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

guard_search_begin :: proc(guard: ^Guard) {
    guard.search.active = true
    guard.search.complete = false
    guard.search.pause_remaining = GUARD_SEARCH_PAUSE
    guard.search.base_facing = guard.facing
    guard.search.angle = 0
    guard.search.direction = -1
    guard.search.sweeps_completed = 0
    guard.behaviour = .SEARCH
}

guard_search_update :: proc(guard: ^Guard, dt: f32) {
    if !guard.search.active || dt <= 0 {
        return
    }

    if guard.search.pause_remaining > 0 {
        guard.search.pause_remaining = max(
            0,
            guard.search.pause_remaining - dt,
        )
        return
    }

    guard.search.angle +=
        guard.search.direction * GUARD_SEARCH_ANGULAR_SPEED * dt

    if guard.search.angle <= -GUARD_SEARCH_HALF_ANGLE {
        guard.search.angle = -GUARD_SEARCH_HALF_ANGLE
        guard.search.direction = 1
    } else if guard.search.angle >= GUARD_SEARCH_HALF_ANGLE {
        guard.search.angle = GUARD_SEARCH_HALF_ANGLE
        guard.search.direction = -1
        guard.search.sweeps_completed += 1

        if guard.search.sweeps_completed >= GUARD_SEARCH_SWEEPS {
            guard.search.active = false
            guard.search.complete = true
            guard.facing = guard.search.base_facing
            return
        }
    }

    c := math.cos(guard.search.angle)
    s := math.sin(guard.search.angle)
    guard.facing = {
        guard.search.base_facing.x*c - guard.search.base_facing.y*s,
        guard.search.base_facing.x*s + guard.search.base_facing.y*c,
    }
}

guard_investigate_update :: proc(
    guard: ^Guard,
    lvl: ^mission.Mission,
    dt: f32,
) {
    if dt <= 0 || guard.speed <= 0 {
        return
    }

    target := guard.awareness.last_known_position

    // Visible pursuit uses direct steering when unobstructed.
    if guard.player_visible && !guard.investigation.ready {
        guard.search.active = false
        guard.search.complete = false
        guard.search.pause_remaining = 0
        guard.search.sweeps_completed = 0
        guard.behaviour = .PURSUE

        _, blocked := guard_step_toward(guard, target, lvl, dt)
        if !blocked {
            return
        }
        // Blocked → fall through to A* below.
    }

    guard_investigation_path_prepare(guard, lvl, target)

    dx_to_target := target.x - guard.position.x
    dy_to_target := target.y - guard.position.y
    distance_to_target := math.sqrt(
        dx_to_target*dx_to_target +
        dy_to_target*dy_to_target,
    )

    // Snap the path index to the end once we are close enough to the
    // investigation target (A* terminates at cell centres).
    if distance_to_target <= 0.15 {
        guard.investigation.index = len(guard.investigation.path)
    }

    if !guard.investigation.found {
        return
    }

    remaining_time := dt

    for remaining_time > 0 {
        if guard.investigation.index >= len(guard.investigation.path) {
            if guard.player_visible {
                path_follower_clear(&guard.investigation)
                return
            }

            if !guard.search.active && !guard.search.complete {
                guard_search_begin(guard)
            }

            if guard.search.active {
                guard_search_update(guard, remaining_time)

                if guard.search.complete &&
                   guard.awareness.state == .SUSPICIOUS &&
                   guard.awareness.last_known_source == .SOUND {
                    guard.awareness.state = .UNAWARE
                    guard.awareness.suspicion = 0
                    guard.awareness.last_known_source = .NONE
                    guard.search.complete = false
                    path_follower_clear(&guard.investigation)
                    guard.behaviour = .PATROL
                } else if guard.search.complete &&
                          guard.awareness.state == .ALERTED {
                    guard.awareness.state = .RECOVERING
                    guard_recovery_begin(guard)
                    path_follower_clear(&guard.investigation)
                }
            }
            return
        }

        left, _ := follow_path(
            guard,
            &guard.investigation,
            lvl,
            remaining_time,
        )
        remaining_time = left

        if !guard.investigation.ready {
            // cleared by collision
            return
        }
    }
}
