
package actors

import "../mission"
import "../geom"
import "core:math"

Vision_Config :: struct {
    range: f32,
    // Cosine of the half-angle of the field of view.
    // 90-degree FOV = cos(45 degrees) = 0.70710678.
    fov_cos: f32,
}

VISION_DEFAULT :: Vision_Config{
    range = 24.0,
    fov_cos = 0.70710678,
}

PERCEPTION_EPSILON :: 0.00001

// Tests whether a 2D segment intersects a rectangle.
// Coordinates use the mission's top-down coordinate space.
segment_intersects_rect :: proc(
    start, finish: geom.Point,
    rect: geom.Rect,
) -> bool {
    dx := finish.x - start.x
    dy := finish.y - start.y

    t_min: f32 = 0
    t_max: f32 = 1

    // Clip against the X interval.
    if dx > -PERCEPTION_EPSILON && dx < PERCEPTION_EPSILON {
        if start.x < rect.x || start.x > rect.x + rect.w {
            return false
        }
    } else {
        tx1 := (rect.x - start.x) / dx
        tx2 := (rect.x + rect.w - start.x) / dx

        t1 := min(tx1, tx2)
        t2 := max(tx1, tx2)

        t_min = max(t_min, t1)
        t_max = min(t_max, t2)

        if t_min > t_max {
            return false
        }
    }

    // Clip against the Y interval.
    if dy > -PERCEPTION_EPSILON && dy < PERCEPTION_EPSILON {
        if start.y < rect.y || start.y > rect.y + rect.h {
            return false
        }
    } else {
        ty1 := (rect.y - start.y) / dy
        ty2 := (rect.y + rect.h - start.y) / dy

        t1 := min(ty1, ty2)
        t2 := max(ty1, ty2)

        t_min = max(t_min, t1)
        t_max = min(t_max, t2)

        if t_min > t_max {
            return false
        }
    }

    return t_max >= 0 && t_min <= 1
}

// Returns true if mission geometry obstructs the line between two points.
// Uses the same baked solids list as collision, so openings are consistent.
mission_line_blocked :: proc(
    level: ^mission.Mission,
    start, finish: geom.Point,
) -> bool {
    mission.ensure_baked(level)

    for s in level.geometry.solids {
        rect := geom.Rect{x = s.x, y = s.y, w = s.w, h = s.h}
        if segment_intersects_rect(start, finish, rect) {
            return true
        }
    }
    // Circles (barrels/trees) remain non-blocking for LOS, matching the
    // previous behaviour.
    return false
}

// Pure visibility query. Does not change guard or mission state.
//
// facing and positions use the mission's 2D coordinate space.
// fov_cos is the cosine of the half-angle of the vision cone.
guard_can_see :: proc(
    observer: geom.Point,
    facing: geom.Point,
    target: geom.Point,
    level: ^mission.Mission,
    vision: Vision_Config,
) -> bool {
    dx := target.x - observer.x
    dy := target.y - observer.y

    distance_sq := dx*dx + dy*dy

    if distance_sq <= PERCEPTION_EPSILON {
        return true
    }

    if distance_sq > vision.range * vision.range {
        return false
    }

    facing_length_sq := facing.x*facing.x + facing.y*facing.y
    if facing_length_sq <= PERCEPTION_EPSILON {
        return false
    }

    distance := math.sqrt(distance_sq)
    facing_length := math.sqrt(facing_length_sq)

    direction_x := dx / distance
    direction_y := dy / distance

    facing_x := facing.x / facing_length
    facing_y := facing.y / facing_length

    dot := facing_x*direction_x + facing_y*direction_y

    if dot < vision.fov_cos {
        return false
    }

    return !mission_line_blocked(level, observer, target)
}
