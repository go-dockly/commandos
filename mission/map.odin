package mission

// Missions on the gameplay map (sandtable's docs/map_spec.md). A mission that
// names a map in "map" plays on it: positions are map metres, every actor has
// a floor height, movement and sight go through gamemap. Without one, the 2D
// geometry below rules as before.
//
// On the map an actor is a body MAP_BODY_RADIUS wide (a person is about
// 0.8 m across), whatever its 2D radius: it may stand anywhere its body's
// cells have a floor within a step of its own.

import "core:math"

import "../gamemap"
import "../geom"

MAP_BODY_RADIUS :: f32(0.4)

has_map :: proc(lvl: ^Mission) -> bool {
    return lvl.has_map
}

// Where a body standing at `point` on the floor at height h would stand:
// the floor under its centre within a step of h, if every cell its body
// covers has a floor within a step of that. Guards also stay out of
// No_Guards cells. 2D missions: the geometry, h unchanged.
step_collides :: proc(lvl: ^Mission, point: geom.Point, radius: f32, h: f32, guard := false) -> (blocked: bool, new_h: f32) {
    if !lvl.has_map {
        return point_collides(lvl, point, radius), h
    }
    m := &lvl.game_map
    agent := MAP_AGENT
    agent.guard = guard
    x, y, inside := gamemap.cell_of(m, {point.x, point.y})
    if !inside do return true, h
    li := gamemap.floor_near(m, x, y, h)
    if li < 0 do return true, h
    centre := gamemap.Node{u16(li), i32(x), i32(y)}
    if !gamemap.standable(m, centre, agent) do return true, h
    floor, _ := gamemap.height(m, centre)

    // the body's rim: 8 points around the centre
    for k in 0 ..< 8 {
        s, c := math.sincos(f32(k) * math.TAU / 8)
        q := [2]f32{point.x + c * MAP_BODY_RADIUS, point.y + s * MAP_BODY_RADIUS}
        qx, qy, qin := gamemap.cell_of(m, q)
        if !qin do return true, h
        if qx == x && qy == y do continue
        ql := gamemap.floor_near(m, qx, qy, floor)
        if ql < 0 do return true, h
        if !gamemap.standable(m, {u16(ql), i32(qx), i32(qy)}, agent) do return true, h
    }
    return false, floor
}

// The agent movement checks use: under a cell, no clearance of its own.
MAP_AGENT :: gamemap.Agent{radius = MAP_BODY_RADIUS}

// The floor height at a point nearest h: snaps an authored position onto the
// map. 2D missions: 0.
floor_at :: proc(lvl: ^Mission, point: geom.Point, h: f32 = 0) -> (f32, bool) {
    if !lvl.has_map do return 0, true
    n, ok := gamemap.node_at(&lvl.game_map, {point.x, point.y, h})
    if !ok do return 0, false
    floor, _ := gamemap.height(&lvl.game_map, n)
    return floor, true
}

// A spot near `point` where a body on the floor nearest h fits: the point
// itself, else the closest of rings of points around it, up to a cell away.
// For landing at the end of a ladder next to the wall it leans on.
settle :: proc(lvl: ^Mission, point: geom.Point, h: f32) -> (geom.Point, f32, bool) {
    if blocked, nh := step_collides(lvl, point, MAP_BODY_RADIUS, h); !blocked do return point, nh, true
    if !lvl.has_map do return point, h, false
    reach := lvl.game_map.cell
    for ring in 1 ..= 5 {
        r := reach * f32(ring) / 5
        for k in 0 ..< 16 {
            s, c := math.sincos(f32(k) * math.TAU / 16)
            q := geom.Point{point.x + c * r, point.y + s * r}
            if blocked, nh := step_collides(lvl, q, MAP_BODY_RADIUS, h); !blocked do return q, nh, true
        }
    }
    return point, h, false
}
