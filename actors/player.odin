package actors

import "../gamemap"
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
// How close to a link's end (a ladder's foot, its top) the player must be to
// take it with interact, metres.
LINK_REACH :: f32(1.2)

// Taking a link: the player is on it for its time, then lands at the far end.
Player_Climb :: struct {
    active:   bool,
    link:     int,
    from, to: geom.Point,
    from_h, to_h: f32,
    spent, total: f32,
    noise:    f32, // heard this far when he gets off
}

Player :: struct {
    position: geom.Point,
    h: f32,         // floor height on a map, metres; 0 on 2D missions
    crouched: bool, // sneaking is crouching: hidden behind low cover
    abilities: gamemap.Abilities,
    climb: Player_Climb,
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
    if p.climb.active {
        return player_climb_update(p, level, dt)
    }

    sneaking := input.sneak
    running := input.run && !sneaking
    p.crouched = sneaking

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

    if blocked, h := mission.step_collides(level, next, p.radius, p.h); !blocked {
        p.position.x = next.x
        p.h = h
    } else {
        p.velocity.x = 0
    }

    next = p.position
    next.y += p.velocity.y * dt

    if blocked, h := mission.step_collides(level, next, p.radius, p.h); !blocked {
        p.position.y = next.y
        p.h = h
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

// The player's stance for sight.
player_stance :: proc(p: Player) -> gamemap.Stance {
    return .Crouching if p.crouched else .Standing
}

// Interact next to a link's end: starts taking the nearest one he may use
// (a ladder up onto a roof, back down; a drop only downwards). true if he
// did. Only on a map.
player_try_link :: proc(p: ^Player, level: ^mission.Mission) -> bool {
    if !level.has_map || p.climb.active do return false
    m := &level.game_map
    agent := gamemap.Agent{abilities = p.abilities}
    best, best_d := -1, LINK_REACH
    from_a := true
    for l, i in m.links {
        if !gamemap.link_usable(l, agent) do continue
        for end in 0 ..< 2 {
            if end == 1 && l.kind == .Drop do continue
            place := l.a if end == 0 else l.b
            n := gamemap.Node{u16(place.layer), i32(place.x), i32(place.y)}
            eh, ok := gamemap.height(m, n)
            if !ok || abs(eh - p.h) > gamemap.STEP do continue
            c := gamemap.cell_centre(m, place.x, place.y)
            d := math.sqrt((c.x - p.position.x) * (c.x - p.position.x) + (c.y - p.position.y) * (c.y - p.position.y))
            if d <= best_d {
                best, best_d = i, d
                from_a = end == 0
            }
        }
    }
    if best < 0 do return false
    l := m.links[best]
    far := l.b if from_a else l.a
    to_n := gamemap.Node{u16(far.layer), i32(far.x), i32(far.y)}
    to_h, _ := gamemap.height(m, to_n)
    c := gamemap.cell_centre(m, far.x, far.y)
    p.climb = Player_Climb{
        active = true, link = best,
        from = p.position, to = {c.x, c.y},
        from_h = p.h, to_h = to_h,
        total = gamemap.link_cost(l),
        noise = l.noise,
    }
    p.velocity = {}
    return true
}

// On a link: moves along it, lands at the far end when its time is up.
// true on the frame he gets off (a noise as loud as the link).
player_climb_update :: proc(p: ^Player, level: ^mission.Mission, dt: f32) -> bool {
    c := &p.climb
    c.spent += dt
    t := min(c.spent / c.total, 1) if c.total > 0 else 1
    p.position = {c.from.x + (c.to.x - c.from.x) * t, c.from.y + (c.to.y - c.from.y) * t}
    p.h = c.from_h + (c.to_h - c.from_h) * t
    if t < 1 do return false
    spot, h, _ := mission.settle(level, c.to, c.to_h)
    p.position, p.h = spot, h
    p.footstep_noise_radius = c.noise
    p.footstep_noise_intensity = PLAYER_WALK_NOISE_INTENSITY
    c^ = {}
    return true
}
