package actors

import "../mission"
import "../geom"

import "core:math"

PLAYER_WALK_SPEED :: 12.0
PLAYER_SNEAK_SPEED :: 4.5
PLAYER_RUN_SPEED :: 18.0

PLAYER_WALK_INTERVAL :f32: 0.45
PLAYER_SNEAK_INTERVAL :: 0.70
PLAYER_RUN_INTERVAL :: 0.30

PLAYER_WALK_NOISE_RADIUS :: 18.0
PLAYER_SNEAK_NOISE_RADIUS :: 6.0
PLAYER_RUN_NOISE_RADIUS :: 30.0

PLAYER_WALK_NOISE_INTENSITY :: 1.0
PLAYER_SNEAK_NOISE_INTENSITY :: 0.35
PLAYER_RUN_NOISE_INTENSITY :: 1.5

// Player lives entirely in mission space. The renderer lifts position/facing
// into 3D when drawing; simulation never sees a Vector3.
Player :: struct {
    position: geom.Point,
    velocity: geom.Point,
    facing: geom.Point,
    radius: f32,
    move_speed: f32,
    acceleration: f32,
    deceleration: f32,
    footstep_timer: f32,
    footstep_noise_radius: f32,
    footstep_noise_intensity: f32,
}

player_init :: proc(position: geom.Point) -> Player {
    return Player{
        position = position,
        facing = {0, -1},
        radius = 0.8,
        move_speed = 12.0,
        acceleration = 36.0,
        deceleration = 48.0,
        footstep_timer = 0,
        footstep_noise_radius = PLAYER_WALK_NOISE_RADIUS,
        footstep_noise_intensity = PLAYER_WALK_NOISE_INTENSITY,
    }
}

// Advances the player by dt using the given input.
// Returns true on the frame a footstep is emitted.
player_update :: proc(
    p: ^Player,
    input: Input,
    level: ^mission.Mission,
    dt: f32,
) -> bool {
    sneaking := input.sneak
    running := input.run && !sneaking

    if sneaking {
        p.move_speed = PLAYER_SNEAK_SPEED
        p.footstep_noise_radius = PLAYER_SNEAK_NOISE_RADIUS
        p.footstep_noise_intensity = PLAYER_SNEAK_NOISE_INTENSITY
    } else if running {
        p.move_speed = PLAYER_RUN_SPEED
        p.footstep_noise_radius = PLAYER_RUN_NOISE_RADIUS
        p.footstep_noise_intensity = PLAYER_RUN_NOISE_INTENSITY
    } else {
        p.move_speed = PLAYER_WALK_SPEED
        p.footstep_noise_radius = PLAYER_WALK_NOISE_RADIUS
        p.footstep_noise_intensity = PLAYER_WALK_NOISE_INTENSITY
    }

    // input.move is already mission-space (x, y).
    move := geom.Point{input.move.x, input.move.y}
    move_length := math.sqrt(move.x * move.x + move.y * move.y)

    desired := geom.Point{}
    if move_length > 0 {
        desired = geom.Point{
            move.x * (p.move_speed / move_length),
            move.y * (p.move_speed / move_length),
        }
    }

    delta := geom.Point{
        desired.x - p.velocity.x,
        desired.y - p.velocity.y,
    }
    delta_length := math.sqrt(delta.x * delta.x + delta.y * delta.y)

    rate := p.acceleration
    if move_length == 0 do rate = p.deceleration

    max_change := rate * dt

    if delta_length > max_change && delta_length > 0 {
        p.velocity.x += delta.x * (max_change / delta_length)
        p.velocity.y += delta.y * (max_change / delta_length)
    } else {
        p.velocity = desired
    }

    velocity_length := math.sqrt(
        p.velocity.x * p.velocity.x +
        p.velocity.y * p.velocity.y,
    )

    if velocity_length > 0.1 {
        p.facing = {
            p.velocity.x / velocity_length,
            p.velocity.y / velocity_length,
        }
    }

    next := p.position
    next.x += p.velocity.x * dt

    if !mission.point_collides(level, next, p.radius) {
        p.position.x = next.x
    } else {
        p.velocity.x = 0
    }

    next = p.position
    next.y += p.velocity.y * dt

    if !mission.point_collides(level, next, p.radius) {
        p.position.y = next.y
    } else {
        p.velocity.y = 0
    }

    bounds := mission.bounds(level)
    p.position.x = math.clamp(p.position.x, p.radius, bounds.width - p.radius)
    p.position.y = math.clamp(p.position.y, p.radius, bounds.height - p.radius)

    interval := PLAYER_WALK_INTERVAL
    if sneaking {
        interval = PLAYER_SNEAK_INTERVAL
    } else if running {
        interval = PLAYER_RUN_INTERVAL
    }

    speed := math.sqrt(p.velocity.x*p.velocity.x + p.velocity.y*p.velocity.y)

    if speed > 0.5 {
        p.footstep_timer -= dt
        if p.footstep_timer <= 0 {
            p.footstep_timer = interval
            return true
        }
    } else {
        p.footstep_timer = 0
    }

    return false
}
