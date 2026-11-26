package geom

import "core:math"
 
// Single simulation coordinate type. The whole gameplay layer works in this
// 2D top-down space. Mapping to 3D (x, height, y) happens only in the renderer.
Point :: struct {
    x: f32,
    y: f32,
}

// Authoring bounds of the mission plane. Loaded from coordinateSpace in JSON;
// defaults keep older missions working.
Bounds :: struct {
    width:  f32,
    height: f32,
}

Wall :: struct {
    id: string,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    openings: []Opening,
}

// A gap in a wall, measured along the wall's long axis: it starts at y and
// spans h. (The names are historical; they apply to horizontal walls too.)
Opening :: struct {
    id: string,
    y: f32,
    h: f32,
}

Cover :: struct {
    kind: string `json:"type"`,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: f32,
}

// Runtime collision / LOS geometry produced by bake.
// Openings are expanded into solid segments so every consumer sees the same
// shape. Horizontal and vertical walls are both supported.
// What a baked solid was authored as. Collision and line of sight ignore it;
// the renderer uses it to pick a height and colour, so it can draw straight
// from the baked list instead of re-deriving wall openings from the JSON.
Kind :: enum u8 {
    BUILDING,
    WALL,
    CRATE,
    BARREL,
    TREE,
}

Rect :: struct {
    id: string,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
}

// A baked, collidable rectangle. Unlike Rect it carries no authoring id, but
// remembers what it was authored as.
Solid :: struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    kind: Kind,
}

Circle :: struct {
    x, y, r: f32,
    kind: Kind,
}

Geometry :: struct {
    solids:  []Solid,  // buildings, wall segments, crates
    circles: []Circle, // barrels, trees (collision only)
    baked:   bool,
}

circle_hits_box :: proc(
    x, z, radius: f32,
    min_x, min_z, max_x, max_z: f32,
) -> bool {
    closest_x := math.clamp(x, min_x, max_x)
    closest_z := math.clamp(z, min_z, max_z)
    dx := x - closest_x
    dz := z - closest_z
    return dx*dx + dz*dz < radius*radius
}

circle_hits_circle :: proc(
    x, z, radius: f32,
    cx, cz, other_radius: f32,
) -> bool {
    dx := x - cx
    dz := z - cz
    combined := radius + other_radius
    return dx*dx + dz*dz < combined*combined
}

// Collision query against already-baked geometry. geom.point_collides is
// the Mission-level wrapper that makes sure the geometry is baked first.
point_collides :: proc(
    geo: ^Geometry,
    point: Point,
    radius: f32,
) -> bool {
    for s in geo.solids {
        if circle_hits_box(point.x, point.y, radius, s.x, s.y, s.x + s.w, s.y + s.h) {
            return true
        }
    }
    for c in geo.circles {
        if circle_hits_circle(point.x, point.y, radius, c.x, c.y, c.r) {
            return true
        }
    }
    return false
}

destroy :: proc(geo: ^Geometry) {
    delete(geo.solids)
    delete(geo.circles)
    geo^ = {}
}