package gamemap

// The gameplay map (docs/map_spec.md in sandtable): a layered grid that
// decides where characters can go and what guards can see. It is never
// drawn in the game; the capture is the picture, this is the rules.
//
//   layer 0        the ground, every cell of the map
//   layers 1..     roofs, upper floors, platforms: each covers a window of
//                  the map's cells (sparse), stands at its own heights
//   spans          per map cell up to two solid intervals [bottom, top]:
//                  buildings, walls, canopies, cars. Sight is blocked by them
//   links          stairs, ladders, doors, windows, drops and climbs between
//                  two places walking alone cannot join
//   features       the buildings, trees, walls and props the cells were
//                  stamped from, by id, so edits can point at them
//   interiors      small maps of their own, entered through a door link
//
// Map units are metres: x right and y down in the top view, h up from the
// frame's ground reference. Cells are `cell` metres square; cell (x, y)
// covers [x, x+1) * cell by [y, y+1) * cell.
//
// No raylib, no clock, no randomness: the same map and inputs give the same
// answer on every machine. sandtable previews with this package and the game
// runs on it, so what the editor shows is what guards will do.
//
//   odin test gamemap

import "base:runtime"
import "core:math"
import vmem "core:mem/virtual"

FORMAT  :: "commandos-map"
VERSION :: 1

// A cell height that means "not walkable".
NO_FLOOR :: i16(-32768)

// The highest step between neighbouring cells a character walks up.
STEP :: f32(0.4)
// The deepest a drop link may go.
MAX_DROP :: f32(3)

Surface :: enum u8 {
    Ground,
    Road,
    Grass,
    Gravel,
    Roof,
    Floor,
    Water,
    Deep, // impassable
}

Cover :: enum u8 {
    None,
    Low,  // hides someone crouching
    High, // hides someone standing
}

Flag :: enum u8 {
    Crawl_Only,
    No_Guards,
    Indoors,
}
Flags :: bit_set[Flag; u8]

// Where the map sits in the capture. World to map: subtract the origin,
// rotate by -yaw, divide by the world scale; heights from `ground`.
Frame :: struct {
    origin:      [2]f32 `json:"origin"`,     // world x, z of map (0, 0)
    size:        [2]f32 `json:"size"`,       // metres
    yaw:         f32    `json:"yaw"`,        // degrees: the map's +x turned from world +x, +x towards +z
    world_scale: f32    `json:"worldScale"`, // world units per metre
    ground:      f32    `json:"ground"`,     // world y of h = 0
}

Layer :: struct {
    name:    string,
    x, y:    int, // the window of map cells it covers; layer 0: 0, 0, w, h
    w, h:    int,
    height:  []i16, // centimetres; NO_FLOOR: not walkable
    surface: []Surface,
    cover:   []Cover,
    flags:   []Flags,
}

// A solid interval of a cell, centimetres from the ground reference.
// Empty when top <= bottom.
Span :: struct {
    bottom, top: i16,
}
SPANS :: 2

Link_Kind :: enum u8 {
    Stairs,
    Ladder,
    Door,
    Window,
    Drop,  // a to b only
    Climb, // needs the Climb ability
}

Door_State :: enum u8 {
    Open,
    Closed,
    Locked, // needs the Lockpick ability
}

Ability :: enum u8 {
    None, // everyone
    Climb,
    Lockpick,
}
Abilities :: bit_set[Ability; u8]

// One end of a link. `interior` "" is the map the link is stored in; a name
// is one of that map's interiors.
Place :: struct {
    interior: string `json:"interior,omitempty"`,
    layer:    int    `json:"layer"`,
    x:        int    `json:"x"`,
    y:        int    `json:"y"`,
}

Link :: struct {
    id:      string     `json:"id"`,
    kind:    Link_Kind  `json:"kind"`,
    a:       Place      `json:"a"`,
    b:       Place      `json:"b"`,
    cost:    f32        `json:"cost"`,    // seconds
    noise:   f32        `json:"noise"`,   // metres it is heard at
    ability: Ability    `json:"ability"`, // who may use it besides what the kind needs
    door:    Door_State `json:"door"`,    // starting state; the game keeps the current one
}

Feature_Kind :: enum u8 {
    Building,
    Tree,
    Wall,
    Volume, // a solid added by hand
    Prop,   // a placed GLB
}

Roof :: enum u8 {
    Flat,
    Gable, // stamped flat at the ridge for now
}

// A thing the cells were stamped from. Footprints are rings in map metres,
// filled even-odd, so a courtyard is a second ring.
Feature :: struct {
    id:            string     `json:"id"`,
    kind:          Feature_Kind `json:"kind"`,
    footprint:     [][][2]f32 `json:"footprint"`,
    base:          f32        `json:"base"`,   // h of its foot
    height:        f32        `json:"height"`, // its top, above base
    bottom:        f32        `json:"bottom"`, // solid from base + bottom: a canopy's underside; 0 for most
    roof:          Roof       `json:"roof"`,
    walkable_roof: bool       `json:"walkableRoof"`,
    trunk:         f32        `json:"trunk"`,  // trees: trunk radius
    at:            [2]f32     `json:"at"`,     // trees: trunk centre
}

Interior :: struct {
    id:       string,
    building: string, // the feature it belongs to
    m:        Map,
}

Map :: struct {
    frame:     Frame,
    cell:      f32, // metres
    w, h:      int,
    layers:    [dynamic]Layer,
    spans:     [][SPANS]Span, // w * h
    links:     [dynamic]Link,
    features:  [dynamic]Feature,
    interiors: [dynamic]Interior,
    // features are stamped into the cells (apply_edits); before that the map
    // is the bare automatic map
    stamped:   bool,

    // the layers covering each cell with a floor, for movement between
    // layers and node_at: cell c's are stack[stack_start[c]:stack_start[c+1]]
    stack_start: []i32,
    stack:       []u16,

    allocator: runtime.Allocator,
    arena:     ^vmem.Arena, // the top map owns everything; nil for interiors
}

Node :: struct {
    layer: u16,
    x, y:  i32,
}

// ---------------------------------------------------------------------------
// Making and freeing
// ---------------------------------------------------------------------------

// A map of w x h cells with a ground layer that is not walkable anywhere yet
// and no spans. Everything it holds lives in one arena; destroy frees it.
make_map :: proc(frame: Frame, cell: f32, w, h: int) -> Map {
    arena := new(vmem.Arena)
    _ = vmem.arena_init_growing(arena)
    m := init_map(vmem.arena_allocator(arena), frame, cell, w, h)
    m.arena = arena
    return m
}

@(private)
init_map :: proc(allocator: runtime.Allocator, frame: Frame, cell: f32, w, h: int) -> Map {
    m: Map
    m.allocator = allocator
    m.frame = frame
    m.cell = cell if cell > 0 else 1
    m.w, m.h = max(w, 1), max(h, 1)
    m.layers = make([dynamic]Layer, allocator)
    m.links = make([dynamic]Link, allocator)
    m.features = make([dynamic]Feature, allocator)
    m.interiors = make([dynamic]Interior, allocator)
    m.spans = make([][SPANS]Span, m.w * m.h, allocator)
    add_layer(&m, "ground", 0, 0, m.w, m.h)
    reindex(&m)
    return m
}

destroy :: proc(m: ^Map) {
    if m == nil do return
    if m.arena != nil {
        vmem.arena_destroy(m.arena)
        free(m.arena)
    }
    m^ = {}
}

// Adds a layer over a window of cells, not walkable anywhere, and returns its
// index. The window is clipped to the map.
add_layer :: proc(m: ^Map, name: string, x, y, w, h: int) -> int {
    x0, y0 := clamp(x, 0, m.w), clamp(y, 0, m.h)
    x1, y1 := clamp(x + w, 0, m.w), clamp(y + h, 0, m.h)
    l := Layer{name = clone(m, name), x = x0, y = y0, w = max(x1 - x0, 0), h = max(y1 - y0, 0)}
    n := l.w * l.h
    l.height = make([]i16, n, m.allocator)
    l.surface = make([]Surface, n, m.allocator)
    l.cover = make([]Cover, n, m.allocator)
    l.flags = make([]Flags, n, m.allocator)
    for &v in l.height do v = NO_FLOOR
    append(&m.layers, l)
    return len(m.layers) - 1
}

layer_index :: proc(m: ^Map, name: string) -> (int, bool) {
    for l, i in m.layers {
        if l.name == name do return i, true
    }
    return -1, false
}

@(private)
clone :: proc(m: ^Map, s: string) -> string {
    if len(s) == 0 do return ""
    b := make([]byte, len(s), m.allocator)
    copy(b, s)
    return string(b)
}

// Rebuilds the per-cell layer stacks. Call after changing which cells of
// which layers have a floor (apply_edits and load do).
reindex :: proc(m: ^Map) {
    n := m.w * m.h
    start := make([]i32, n + 1, m.allocator)
    for l in m.layers {
        for ly in 0 ..< l.h {
            for lx in 0 ..< l.w {
                if l.height[ly * l.w + lx] != NO_FLOOR do start[(l.y + ly) * m.w + l.x + lx + 1] += 1
            }
        }
    }
    for c in 0 ..< n do start[c + 1] += start[c]
    stack := make([]u16, start[n], m.allocator)
    fill := make([]i32, n, context.temp_allocator)
    copy(fill, start[:n])
    for l, li in m.layers {
        for ly in 0 ..< l.h {
            for lx in 0 ..< l.w {
                if l.height[ly * l.w + lx] == NO_FLOOR do continue
                c := (l.y + ly) * m.w + l.x + lx
                stack[fill[c]] = u16(li)
                fill[c] += 1
            }
        }
    }
    m.stack_start = start
    m.stack = stack
}

// The layers with a floor at map cell (x, y), in layer order.
layers_at :: proc(m: ^Map, x, y: int) -> []u16 {
    if x < 0 || y < 0 || x >= m.w || y >= m.h || len(m.stack_start) != m.w * m.h + 1 do return nil
    c := y * m.w + x
    return m.stack[m.stack_start[c]:m.stack_start[c + 1]]
}

// ---------------------------------------------------------------------------
// Cells
// ---------------------------------------------------------------------------

in_map :: #force_inline proc(m: ^Map, x, y: int) -> bool {
    return x >= 0 && y >= 0 && x < m.w && y < m.h
}

// The index of map cell (x, y) in a layer's arrays.
layer_cell :: #force_inline proc(l: ^Layer, x, y: int) -> (int, bool) {
    lx, ly := x - l.x, y - l.y
    if lx < 0 || ly < 0 || lx >= l.w || ly >= l.h do return -1, false
    return ly * l.w + lx, true
}

cm :: #force_inline proc(metres: f32) -> i16 {
    return i16(clamp(math.round(metres * 100), -32767, 32767))
}

metres :: #force_inline proc(centimetres: i16) -> f32 {
    return f32(centimetres) / 100
}

// The standing height of a node, metres, and whether it is walkable.
height :: proc(m: ^Map, n: Node) -> (f32, bool) {
    if int(n.layer) >= len(m.layers) do return 0, false
    l := &m.layers[n.layer]
    i, ok := layer_cell(l, int(n.x), int(n.y))
    if !ok || l.height[i] == NO_FLOOR do return 0, false
    return metres(l.height[i]), true
}

walkable :: proc(m: ^Map, n: Node) -> bool {
    _, ok := height(m, n)
    return ok
}

surface_at :: proc(m: ^Map, n: Node) -> Surface {
    l := &m.layers[n.layer]
    i, ok := layer_cell(l, int(n.x), int(n.y))
    return l.surface[i] if ok else .Deep
}

cover_at :: proc(m: ^Map, n: Node) -> Cover {
    l := &m.layers[n.layer]
    i, ok := layer_cell(l, int(n.x), int(n.y))
    return l.cover[i] if ok else .None
}

flags_at :: proc(m: ^Map, n: Node) -> Flags {
    l := &m.layers[n.layer]
    i, ok := layer_cell(l, int(n.x), int(n.y))
    return l.flags[i] if ok else {}
}

// Sets a cell of a layer; false outside its window.
set_cell :: proc(m: ^Map, layer, x, y: int, h: f32, surface := Surface.Ground, cover := Cover.None, flags := Flags{}) -> bool {
    l := &m.layers[layer]
    i, ok := layer_cell(l, x, y)
    if !ok do return false
    l.height[i] = cm(h)
    l.surface[i] = surface
    l.cover[i] = cover
    l.flags[i] = flags
    return true
}

block_cell :: proc(m: ^Map, layer, x, y: int) {
    l := &m.layers[layer]
    if i, ok := layer_cell(l, x, y); ok do l.height[i] = NO_FLOOR
}

// The map cell under a point in map metres.
cell_of :: proc(m: ^Map, p: [2]f32) -> (x, y: int, inside: bool) {
    x = int(math.floor(p.x / m.cell))
    y = int(math.floor(p.y / m.cell))
    return x, y, in_map(m, x, y)
}

cell_centre :: proc(m: ^Map, x, y: int) -> [2]f32 {
    return {(f32(x) + 0.5) * m.cell, (f32(y) + 0.5) * m.cell}
}

// A point in map metres (x, y, h) to the node under it: the highest floor at
// or below h + STEP, else the lowest floor of that cell.
node_at :: proc(m: ^Map, p: [3]f32) -> (Node, bool) {
    x, y, inside := cell_of(m, p.xy)
    if !inside do return {}, false
    best, lowest := -1, -1
    best_h, lowest_h := -max(f32), max(f32)
    for li in layers_at(m, x, y) {
        h, _ := height(m, Node{li, i32(x), i32(y)})
        if h <= p.z + STEP && h > best_h {
            best, best_h = int(li), h
        }
        if h < lowest_h {
            lowest, lowest_h = int(li), h
        }
    }
    if best < 0 do best = lowest
    if best < 0 do return {}, false
    return Node{u16(best), i32(x), i32(y)}, true
}

// The centre of a node's cell at its standing height, map metres.
node_point :: proc(m: ^Map, n: Node) -> [3]f32 {
    c := cell_centre(m, int(n.x), int(n.y))
    h, _ := height(m, n)
    return {c.x, c.y, h}
}

spans_at :: proc(m: ^Map, x, y: int) -> [SPANS]Span {
    if !in_map(m, x, y) do return {}
    return m.spans[y * m.w + x]
}

// Adds a solid interval to a cell, merging with what overlaps; with both
// slots taken it widens the nearest one (sight errs on the blocked side).
add_span :: proc(m: ^Map, x, y: int, bottom, top: f32) {
    if !in_map(m, x, y) || top <= bottom do return
    s := &m.spans[y * m.w + x]
    nb, nt := cm(bottom), cm(top)
    for {
        merged := false
        for &e in s {
            if e.top <= e.bottom do continue
            if nb <= e.top && nt >= e.bottom {
                nb, nt = min(nb, e.bottom), max(nt, e.top)
                e = {}
                merged = true
            }
        }
        if !merged do break
    }
    for &e in s {
        if e.top <= e.bottom {
            e = {nb, nt}
            return
        }
    }
    // both full and apart from the new one: widen the closer
    gap :: proc(e: Span, b, t: i16) -> int {
        if t < e.bottom do return int(e.bottom) - int(t)
        return int(b) - int(e.top)
    }
    k := 0 if gap(s[0], nb, nt) <= gap(s[1], nb, nt) else 1
    s[k] = {min(s[k].bottom, nb), max(s[k].top, nt)}
    if s[0].top >= s[1].bottom && s[1].top >= s[0].bottom {
        s[0] = {min(s[0].bottom, s[1].bottom), max(s[0].top, s[1].top)}
        s[1] = {}
    }
}

clear_spans :: proc(m: ^Map, x, y: int) {
    if in_map(m, x, y) do m.spans[y * m.w + x] = {}
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------

// A world point (x, y up, z) to map metres (x, y, h).
world_to_map :: proc(f: Frame, world: [3]f32) -> [3]f32 {
    ws := f.world_scale if f.world_scale > 0 else 1
    s, c := math.sincos(f.yaw * math.RAD_PER_DEG)
    dx, dz := world.x - f.origin.x, world.z - f.origin.y
    return {
        (c * dx + s * dz) / ws,
        (-s * dx + c * dz) / ws,
        (world.y - f.ground) / ws,
    }
}

// Map metres (x, y, h) to a world point.
map_to_world :: proc(f: Frame, p: [3]f32) -> [3]f32 {
    ws := f.world_scale if f.world_scale > 0 else 1
    s, c := math.sincos(f.yaw * math.RAD_PER_DEG)
    x, y := p.x * ws, p.y * ws
    return {
        f.origin.x + c * x - s * y,
        f.ground + p.z * ws,
        f.origin.y + s * x + c * y,
    }
}
