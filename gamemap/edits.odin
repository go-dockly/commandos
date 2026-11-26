package gamemap

// Edits: the manual work on top of the automatic map, applied in order
// every time the map is rebuilt, so rebuilding the terrain never loses them.
//
// apply_edits takes an automatic map: layer 0 holds the bare ground
// everywhere and the features are listed but not yet stamped. It runs:
//
//   1. the edits that change features (building, remove, tree, volume), in order
//   2. stamping every feature into cells, spans and roof layers
//   3. the edits that change cells (flatten, surface, block, unblock) and
//      add links and interiors, in order
//   4. cover from the spans next to each floor
//
// An edit whose target is gone is reported, never dropped: the caller keeps
// its edit list as it was.

import "core:fmt"
import "core:math"
import "core:strings"

Edit_Kind :: enum u8 {
    Flatten,  // region; height, or fit
    Surface,  // region, layer, surface
    Block,    // region, layer
    Unblock,  // region, layer; height or fit
    Building, // target or a new one; footprint, height, roof, walkable roof
    Volume,   // region, bottom, top: a wall, crate stack, other solid
    Remove,   // target
    Tree,     // target or a new one; at, trunk, canopy, height
    Link,     // link kind, a, b (map metres), ability, door, cost
    Interior, // target building, size; a door from a (street) to b (inside)
}

Edit :: struct {
    id:            string       `json:"id"`,
    kind:          Edit_Kind    `json:"kind"`,
    target:        string       `json:"target,omitempty"`, // a feature id
    region:        [][2]f32     `json:"region,omitempty"`, // a polygon, map metres
    layer:         int          `json:"layer,omitempty"`,
    height:        Maybe(f32)   `json:"height,omitempty"`,
    fit:           bool         `json:"fit,omitempty"`,
    surface:       Surface      `json:"surface,omitempty"`,
    footprint:     [][2]f32     `json:"footprint,omitempty"`,
    roof:          Maybe(Roof)  `json:"roof,omitempty"`,
    walkable_roof: Maybe(bool)  `json:"walkableRoof,omitempty"`,
    bottom:        f32          `json:"bottom,omitempty"`,
    top:           f32          `json:"top,omitempty"`,
    at:            [2]f32       `json:"at,omitempty"`,
    trunk:         f32          `json:"trunk,omitempty"`,
    canopy:        f32          `json:"canopy,omitempty"`, // radius
    link:          Link_Kind    `json:"link,omitempty"`,
    a:             [3]f32       `json:"a,omitempty"`,
    b:             [3]f32       `json:"b,omitempty"`,
    ability:       Ability      `json:"ability,omitempty"`,
    door:          Door_State   `json:"door,omitempty"`,
    cost:          f32          `json:"cost,omitempty"`,
    size:          [2]int       `json:"size,omitempty"`, // interior cells
}

Edit_Problem :: struct {
    edit:    string,
    message: string,
}

TREE_TRUNK   :: f32(0.2)  // radius: a trunk about 0.4 m across
CANOPY_BASE  :: f32(3)    // a canopy's underside, at most
COVER_LOW    :: f32(0.9)  // a solid this high next to a floor hides someone crouching
COVER_HIGH   :: f32(1.8)  // and this high someone standing
PASS_UNDER   :: f32(1.8)  // a solid starting this high is walked under

// Applies edits to an automatic map and stamps its features. Problems are
// allocated with `allocator`.
apply_edits :: proc(m: ^Map, edits: []Edit, allocator := context.allocator) -> []Edit_Problem {
    problems := make([dynamic]Edit_Problem, allocator)
    report :: proc(p: ^[dynamic]Edit_Problem, e: Edit, format: string, args: ..any) {
        append(p, Edit_Problem{edit = strings.clone(e.id, p.allocator), message = fmt.aprintf(format, ..args, allocator = p.allocator)})
    }
    if m.stamped {
        append(&problems, Edit_Problem{message = strings.clone("the map's features are stamped already: apply edits to a fresh automatic map", allocator)})
        return problems[:]
    }

    // ---- 1. features -------------------------------------------------------
    for e in edits {
        #partial switch e.kind {
        case .Building:
            fi := feature_index(m, e.target)
            if fi < 0 {
                if e.target != "" && len(e.footprint) < 3 {
                    report(&problems, e, "building %q not found", e.target)
                    continue
                }
                if len(e.footprint) < 3 {
                    report(&problems, e, "a new building needs a footprint")
                    continue
                }
                id := e.target if e.target != "" else e.id
                append(&m.features, Feature{id = clone(m, id), kind = .Building})
                fi = len(m.features) - 1
            }
            f := &m.features[fi]
            if f.kind != .Building {
                report(&problems, e, "%q is a %v, not a building", e.target, f.kind)
                continue
            }
            if len(e.footprint) >= 3 {
                f.footprint = make([][][2]f32, 1, m.allocator)
                f.footprint[0] = clone_ring(m, e.footprint)
                f.base = ground_under(m, f.footprint)
            }
            if h, has := e.height.?; has do f.height = h
            if r, has := e.roof.?; has do f.roof = r
            if w, has := e.walkable_roof.?; has do f.walkable_roof = w
            if f.height <= 0 do report(&problems, e, "building %q has no height", f.id)

        case .Remove:
            fi := feature_index(m, e.target)
            if fi < 0 {
                report(&problems, e, "feature %q not found", e.target)
                continue
            }
            ordered_remove(&m.features, fi)

        case .Tree:
            fi := feature_index(m, e.target)
            if fi < 0 {
                if e.target != "" {
                    report(&problems, e, "tree %q not found", e.target)
                    continue
                }
                append(&m.features, Feature{id = clone(m, e.id), kind = .Tree, at = e.at, trunk = TREE_TRUNK})
                fi = len(m.features) - 1
                f := &m.features[fi]
                f.base = ground_at(m, e.at)
                f.height = 8
            }
            f := &m.features[fi]
            if f.kind != .Tree {
                report(&problems, e, "%q is a %v, not a tree", e.target, f.kind)
                continue
            }
            if e.at != {} do f.at = e.at
            if e.trunk > 0 do f.trunk = e.trunk
            if h, has := e.height.?; has do f.height = h
            if e.canopy > 0 || len(f.footprint) == 0 {
                f.footprint = make([][][2]f32, 1, m.allocator)
                f.footprint[0] = circle(m, f.at, e.canopy if e.canopy > 0 else 2.5)
            }
            f.bottom = min(CANOPY_BASE, 0.4 * f.height)

        case .Volume:
            if len(e.region) < 3 || e.top <= e.bottom {
                report(&problems, e, "a volume needs a region and top above bottom")
                continue
            }
            rings := make([][][2]f32, 1, m.allocator)
            rings[0] = clone_ring(m, e.region)
            append(&m.features, Feature{
                id = clone(m, e.id), kind = .Volume, footprint = rings,
                base = ground_under(m, rings), bottom = e.bottom, height = e.top,
            })
        }
    }

    // ---- 2. stamp ------------------------------------------------------------
    stamp(m)
    reindex(m)

    // ---- 3. cells, links, interiors -----------------------------------------
    dirty := false
    for e in edits {
        #partial switch e.kind {
        case .Flatten:
            rings := [][][2]f32{e.region}
            h, has := e.height.?
            if e.fit || !has do h = mean_floor(m, 0, rings, 0)
            n := 0
            l := &m.layers[0]
            for c in cells_in(m, rings) {
                i, _ := layer_cell(l, c.x, c.y)
                if l.height[i] == NO_FLOOR do continue
                l.height[i] = cm(h)
                n += 1
            }
            if n == 0 do report(&problems, e, "flatten covers no walkable cell")

        case .Surface:
            if e.layer < 0 || e.layer >= len(m.layers) {
                report(&problems, e, "no layer %d", e.layer)
                continue
            }
            l := &m.layers[e.layer]
            for c in cells_in(m, [][][2]f32{e.region}) {
                if i, ok := layer_cell(l, c.x, c.y); ok && l.height[i] != NO_FLOOR do l.surface[i] = e.surface
            }

        case .Block:
            if e.layer < 0 || e.layer >= len(m.layers) {
                report(&problems, e, "no layer %d", e.layer)
                continue
            }
            for c in cells_in(m, [][][2]f32{e.region}) do block_cell(m, e.layer, c.x, c.y)
            dirty = true

        case .Unblock:
            if e.layer < 0 || e.layer >= len(m.layers) {
                report(&problems, e, "no layer %d", e.layer)
                continue
            }
            rings := [][][2]f32{e.region}
            h, has := e.height.?
            if e.fit || !has do h = mean_floor(m, e.layer, rings, 1)
            l := &m.layers[e.layer]
            for c in cells_in(m, rings) {
                i, ok := layer_cell(l, c.x, c.y)
                if !ok || l.height[i] != NO_FLOOR do continue
                l.height[i] = cm(h)
                // a passage opened for walking is opened for sight too
                if e.layer == 0 do clear_spans(m, c.x, c.y)
            }
            dirty = true

        case .Link:
            if dirty {
                reindex(m)
                dirty = false
            }
            a, a_ok := link_end(m, e.a)
            b, b_ok := link_end(m, e.b)
            if !a_ok || !b_ok {
                end := e.a if !a_ok else e.b
                report(&problems, e, "link end %s: no floor within %.1f m of h %.2f at %.2f, %.2f", "a" if !a_ok else "b", LINK_END_REACH, end.z, end.x, end.y)
                continue
            }
            if e.link == .Drop {
                ha, _ := height(m, a)
                hb, _ := height(m, b)
                if ha - hb <= 0 || ha - hb > MAX_DROP {
                    report(&problems, e, "a drop goes down by 0..%.0f m, this one %.2f m", MAX_DROP, ha - hb)
                    continue
                }
            }
            append(&m.links, Link{
                id = clone(m, e.id), kind = e.link,
                a = Place{layer = int(a.layer), x = int(a.x), y = int(a.y)},
                b = Place{layer = int(b.layer), x = int(b.x), y = int(b.y)},
                cost = e.cost if e.cost > 0 else DEFAULT_LINK_COST[e.link],
                noise = DEFAULT_LINK_NOISE[e.link],
                ability = e.ability, door = e.door,
            })

        case .Interior:
            if feature_index(m, e.target) < 0 {
                report(&problems, e, "building %q not found", e.target)
                continue
            }
            if e.size.x <= 0 || e.size.y <= 0 {
                report(&problems, e, "an interior needs a size in cells")
                continue
            }
            if dirty {
                reindex(m)
                dirty = false
            }
            inner := init_map(m.allocator, {}, m.cell, e.size.x, e.size.y)
            for y in 0 ..< inner.h {
                for x in 0 ..< inner.w do set_cell(&inner, 0, x, y, 0, .Floor, .None, {.Indoors})
            }
            reindex(&inner)
            append(&m.interiors, Interior{id = clone(m, e.id), building = clone(m, e.target), m = inner})
            outside, out_ok := link_end(m, e.a)
            inside, in_ok := link_end(&m.interiors[len(m.interiors) - 1].m, e.b)
            if !out_ok || !in_ok {
                report(&problems, e, "the interior's door end %s is not on a floor", "a" if !out_ok else "b")
                continue
            }
            append(&m.links, Link{
                id = clone(m, fmt.tprintf("%s/door", e.id)), kind = .Door,
                a = Place{layer = int(outside.layer), x = int(outside.x), y = int(outside.y)},
                b = Place{interior = clone(m, e.id), layer = int(inside.layer), x = int(inside.x), y = int(inside.y)},
                cost = DEFAULT_LINK_COST[.Door], noise = DEFAULT_LINK_NOISE[.Door], door = e.door,
            })
        }
    }
    if dirty do reindex(m)

    // ---- 4. cover --------------------------------------------------------------
    compute_cover(m)
    m.stamped = true
    return problems[:]
}

// How far a link end's height may be from the floor it lands on.
LINK_END_REACH :: f32(1)

// The floor a link end stands on: the cell's floor nearest its height, if
// that is within LINK_END_REACH. A foot put inside a building (its cell
// has only the roof) is refused, not moved onto the roof.
link_end :: proc(m: ^Map, p: [3]f32) -> (Node, bool) {
    x, y, inside := cell_of(m, p.xy)
    if !inside do return {}, false
    best, best_d := -1, LINK_END_REACH
    for li in layers_at(m, x, y) {
        h, _ := height(m, Node{li, i32(x), i32(y)})
        if d := abs(h - p.z); d <= best_d {
            best, best_d = int(li), d
        }
    }
    if best < 0 do return {}, false
    return Node{u16(best), i32(x), i32(y)}, true
}

feature_index :: proc(m: ^Map, id: string) -> int {
    if id == "" do return -1
    for f, i in m.features {
        if f.id == id do return i
    }
    return -1
}

// ---------------------------------------------------------------------------
// Stamping
// ---------------------------------------------------------------------------

// Stamps every feature into the cells: blocks what can't be walked, adds the
// spans sight is checked against, and gives walkable roofs a layer each
// ("roof/<id>"). Call once, on a map whose ground is bare.
stamp :: proc(m: ^Map) {
    for f in m.features {
        switch f.kind {
        case .Building:
            top := f.base + f.height
            cells := cells_in(m, f.footprint)
            for c in cells {
                block_cell(m, 0, c.x, c.y)
                add_span(m, c.x, c.y, f.base - 1, top)
            }
            if f.walkable_roof && len(cells) > 0 {
                x0, y0, x1, y1 := max(int), max(int), min(int), min(int)
                for c in cells {
                    x0, y0 = min(x0, c.x), min(y0, c.y)
                    x1, y1 = max(x1, c.x), max(y1, c.y)
                }
                li := add_layer(m, fmt.tprintf("roof/%s", f.id), x0, y0, x1 - x0 + 1, y1 - y0 + 1)
                for c in cells do set_cell(m, li, c.x, c.y, top, .Roof)
            }

        case .Wall, .Volume, .Prop:
            for c in cells_in(m, f.footprint) {
                add_span(m, c.x, c.y, f.base + f.bottom - (1 if f.bottom <= 0 else 0), f.base + f.height)
                if f.bottom >= PASS_UNDER do continue
                if f.bottom <= 0 && f.height <= STEP {
                    // a kerb: walked over
                    l := &m.layers[0]
                    i, _ := layer_cell(l, c.x, c.y)
                    if l.height[i] != NO_FLOOR do l.height[i] = max(l.height[i], cm(f.base + f.height))
                    continue
                }
                block_cell(m, 0, c.x, c.y)
            }

        case .Tree:
            top := f.base + f.height
            for c in cells_in(m, f.footprint) do add_span(m, c.x, c.y, f.base + f.bottom, top)
            r := max(f.trunk, 0.01)
            tx, ty, inside := cell_of(m, f.at)
            if inside {
                block_cell(m, 0, tx, ty)
                add_span(m, tx, ty, f.base - 1, top)
            }
            k := int(math.ceil(r / m.cell))
            for dy in -k ..= k {
                for dx in -k ..= k {
                    x, y := tx + dx, ty + dy
                    if !in_map(m, x, y) do continue
                    p := cell_centre(m, x, y) - f.at
                    if p.x * p.x + p.y * p.y > r * r do continue
                    block_cell(m, 0, x, y)
                    add_span(m, x, y, f.base - 1, top)
                }
            }
        }
    }
}

// Marks each floor next to a solid it can hide behind.
compute_cover :: proc(m: ^Map) {
    for &l in m.layers {
        for ly in 0 ..< l.h {
            for lx in 0 ..< l.w {
                i := ly * l.w + lx
                if l.height[i] == NO_FLOOR do continue
                floor := metres(l.height[i])
                best := Cover.None
                for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
                    for s in spans_at(m, l.x + lx + d.x, l.y + ly + d.y) {
                        if s.top <= s.bottom do continue
                        if metres(s.bottom) > floor + 0.5 do continue // a canopy, not cover
                        rise := metres(s.top) - floor
                        if rise >= COVER_HIGH {
                            best = .High
                        } else if rise >= COVER_LOW && best == .None {
                            best = .Low
                        }
                    }
                }
                l.cover[i] = best
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Polygons
// ---------------------------------------------------------------------------

// Whether a point is inside rings, even-odd.
inside_rings :: proc(rings: [][][2]f32, p: [2]f32) -> bool {
    inside := false
    for ring in rings {
        n := len(ring)
        for i, j := 0, n - 1; i < n; j, i = i, i + 1 {
            a, b := ring[i], ring[j]
            if (a.y > p.y) != (b.y > p.y) {
                x := a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x do inside = !inside
            }
        }
    }
    return inside
}

// The map cells whose centres are inside rings; temp-allocated.
cells_in :: proc(m: ^Map, rings: [][][2]f32) -> [][2]int {
    out := make([dynamic][2]int, context.temp_allocator)
    lo := [2]f32{max(f32), max(f32)}
    hi := [2]f32{-max(f32), -max(f32)}
    for ring in rings {
        for p in ring {
            lo = {min(lo.x, p.x), min(lo.y, p.y)}
            hi = {max(hi.x, p.x), max(hi.y, p.y)}
        }
    }
    if lo.x > hi.x do return out[:]
    x0 := max(int(math.floor(lo.x / m.cell)), 0)
    y0 := max(int(math.floor(lo.y / m.cell)), 0)
    x1 := min(int(math.ceil(hi.x / m.cell)), m.w - 1)
    y1 := min(int(math.ceil(hi.y / m.cell)), m.h - 1)
    for y in y0 ..= y1 {
        for x in x0 ..= x1 {
            if inside_rings(rings, cell_centre(m, x, y)) do append(&out, [2]int{x, y})
        }
    }
    return out[:]
}

// The mean floor of a layer over rings grown by `grow` cells; 0 if none.
@(private)
mean_floor :: proc(m: ^Map, layer: int, rings: [][][2]f32, grow: int) -> f32 {
    l := &m.layers[layer]
    sum, n := f32(0), 0
    seen := make(map[[2]int]bool, allocator = context.temp_allocator)
    for c in cells_in(m, rings) {
        for dy in -grow ..= grow {
            for dx in -grow ..= grow {
                k := [2]int{c.x + dx, c.y + dy}
                if k in seen do continue
                seen[k] = true
                i, ok := layer_cell(l, k.x, k.y)
                if !ok || l.height[i] == NO_FLOOR do continue
                sum += metres(l.height[i])
                n += 1
            }
        }
    }
    return sum / f32(n) if n > 0 else 0
}

// The mean bare ground under rings (before stamping), metres.
ground_under :: proc(m: ^Map, rings: [][][2]f32) -> f32 {
    return mean_floor(m, 0, rings, 0)
}

ground_at :: proc(m: ^Map, p: [2]f32) -> f32 {
    x, y, inside := cell_of(m, p)
    if !inside do return 0
    h, ok := height(m, Node{0, i32(x), i32(y)})
    return h if ok else 0
}

@(private)
clone_ring :: proc(m: ^Map, ring: [][2]f32) -> [][2]f32 {
    out := make([][2]f32, len(ring), m.allocator)
    copy(out, ring)
    return out
}

// A 16-gon, for canopies.
circle :: proc(m: ^Map, c: [2]f32, r: f32) -> [][2]f32 {
    out := make([][2]f32, 16, m.allocator)
    for i in 0 ..< 16 {
        s, co := math.sincos(f32(i) * math.TAU / 16)
        out[i] = c + r * [2]f32{co, s}
    }
    return out
}
