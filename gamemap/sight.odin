package gamemap

// Sight: a 3D ray from an eye to a point, walked cell by cell over the map
// (Amanatides & Woo). In each cell it crosses, the ray covers a height
// interval; it is blocked where that interval meets a solid span, or dips
// below the ground. The eye's own cell and the target's are not checked, so
// someone standing on a roof or under a canopy is not hidden by it.
//
// Vision cones (range, angle, near and far zones) are game rules; they call
// can_see / can_see_body. `visible` fills a cone per cell, for drawing.

import "core:math"

Stance :: enum u8 {
    Standing,
    Crouching,
    Prone,
}

// Eye height above the floor, metres.
EYE := [Stance]f32{
    .Standing  = 1.7,
    .Crouching = 1.0,
    .Prone     = 0.3,
}

// The points of a body that count as seen, metres above the floor.
BODY := [Stance][]f32{
    .Standing  = {0.2, 1.0, 1.6},
    .Crouching = {0.2, 0.8},
    .Prone     = {0.2},
}

// The eye of someone standing on a floor at foot (map metres).
eye_point :: proc(foot: [3]f32, stance: Stance) -> [3]f32 {
    return {foot.x, foot.y, foot.z + EYE[stance]}
}

// Whether the straight line from eye to target is clear. Map metres.
can_see :: proc(m: ^Map, eye, target: [3]f32) -> bool {
    a := eye.xy / m.cell
    b := target.xy / m.cell
    d := b - a

    cx, cy := int(math.floor(a.x)), int(math.floor(a.y))
    ex, ey := int(math.floor(b.x)), int(math.floor(b.y))
    if cx == ex && cy == ey do return true

    sx := 1 if d.x > 0 else -1
    sy := 1 if d.y > 0 else -1
    INF :: max(f32)
    t_max_x, t_max_y := INF, INF
    t_dx, t_dy := INF, INF
    if d.x != 0 {
        next := f32(cx + 1) if d.x > 0 else f32(cx)
        t_max_x = (next - a.x) / d.x
        t_dx = abs(1 / d.x)
    }
    if d.y != 0 {
        next := f32(cy + 1) if d.y > 0 else f32(cy)
        t_max_y = (next - a.y) / d.y
        t_dy = abs(1 / d.y)
    }

    dz := target.z - eye.z
    t_in := f32(0)
    // the walk crosses at most this many cells
    steps := abs(ex - cx) + abs(ey - cy) + 2
    for _ in 0 ..< steps {
        t_out := min(t_max_x, t_max_y, 1)
        if !(cx == ex && cy == ey) && t_in > 0 {
            if blocks(m, cx, cy, eye.z + dz * t_in, eye.z + dz * t_out) do return false
        }
        if cx == ex && cy == ey do return true
        if t_out >= 1 do return true
        t_in = t_out
        if t_max_x < t_max_y {
            cx += sx
            t_max_x += t_dx
        } else {
            cy += sy
            t_max_y += t_dy
        }
    }
    return true
}

// Whether a ray crossing cell (x, y) between heights h0 and h1 is stopped.
@(private)
blocks :: proc(m: ^Map, x, y: int, h0, h1: f32) -> bool {
    if !in_map(m, x, y) do return false
    lo, hi := min(h0, h1), max(h0, h1)
    for s in m.spans[y * m.w + x] {
        if s.top <= s.bottom do continue
        if lo < metres(s.top) && hi > metres(s.bottom) do return true
    }
    g := m.layers[0].height[y * m.w + x]
    return g != NO_FLOOR && lo < metres(g)
}

// Whether any point of a body standing at foot (map metres, h its floor) in
// a stance is seen from eye.
can_see_body :: proc(m: ^Map, eye, foot: [3]f32, stance: Stance) -> bool {
    for h in BODY[stance] {
        if can_see(m, eye, {foot.x, foot.y, foot.z + h}) do return true
    }
    return false
}

// Whether a point is inside a cone: within range (horizontally) and within
// fov / 2 of facing. Angles in radians, measured from map +x towards +y.
in_cone :: proc(eye: [3]f32, facing, fov, range: f32, p: [2]f32) -> bool {
    d := p - eye.xy
    dist2 := d.x * d.x + d.y * d.y
    if dist2 > range * range do return false
    if dist2 < 1e-6 do return true
    f := [2]f32{math.cos(facing), math.sin(facing)}
    return (d.x * f.x + d.y * f.y) / math.sqrt(dist2) >= math.cos(fov / 2) - 1e-6
}

// Fills out (w * h, row-major) with whether someone in a stance standing on
// any floor of each cell inside the cone would be seen. Cells outside the
// cone are false.
visible :: proc(m: ^Map, eye: [3]f32, facing, fov, range: f32, out: []bool, stance := Stance.Standing) {
    for &v in out do v = false
    if len(out) < m.w * m.h do return
    r := int(math.ceil(range / m.cell)) + 1
    ex, ey, _ := cell_of(m, eye.xy)
    for y in max(ey - r, 0) ..< min(ey + r + 1, m.h) {
        for x in max(ex - r, 0) ..< min(ex + r + 1, m.w) {
            c := cell_centre(m, x, y)
            if !in_cone(eye, facing, fov, range, c) do continue
            for li in layers_at(m, x, y) {
                h, _ := height(m, Node{li, i32(x), i32(y)})
                if can_see_body(m, eye, {c.x, c.y, h}, stance) {
                    out[y * m.w + x] = true
                    break
                }
            }
        }
    }
}
