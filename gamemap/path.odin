package gamemap

// Movement: one A* over (layer, x, y) nodes, walking between neighbouring
// cells plus links. Costs are seconds.
//
// Walking joins a cell to its 8 neighbours when the neighbour has a floor
// within STEP of this one, on any layer (so a roof meets the roof next door
// at the same height). A diagonal also needs both cells beside it, so
// nobody cuts a corner. Water is slower, crawl-only cells slower still,
// deep water and No_Guards cells (for guards) are closed.

import "core:math"

DEFAULT_SPEED :: f32(1.4) // m/s, a walk

Agent :: struct {
    radius:    f32, // metres; under a cell needs no clearance check
    speed:     f32, // m/s on open ground; 0: DEFAULT_SPEED
    abilities: Abilities,
    guard:     bool, // kept out of No_Guards cells
}

Path :: struct {
    nodes: []Node,
    links: []int, // the link taken to arrive at nodes[i]; -1 walked
    cost:  f32,   // seconds
    found: bool,
}

path_destroy :: proc(p: ^Path, allocator := context.allocator) {
    delete(p.nodes, allocator)
    delete(p.links, allocator)
    p^ = {}
}

// Whether an agent may use a link at all, in its direction a -> b.
link_usable :: proc(l: Link, agent: Agent) -> bool {
    if l.a.interior != "" || l.b.interior != "" do return false // into an interior: not this search
    if l.ability != .None && l.ability not_in agent.abilities do return false
    switch l.kind {
    case .Climb:
        if .Climb not_in agent.abilities do return false
    case .Door:
        if l.door == .Locked && .Lockpick not_in agent.abilities do return false
    case .Stairs, .Ladder, .Window, .Drop:
    }
    return true
}

@(private)
Open :: struct {
    node:  i32,
    score: f32,
}

@(private)
open_less :: #force_inline proc(a, b: Open) -> bool {
    if a.score != b.score do return a.score < b.score
    return a.node < b.node
}

@(private)
heap_push :: proc(h: ^[dynamic]Open, o: Open) {
    append(h, o)
    c := len(h) - 1
    for c > 0 {
        p := (c - 1) / 2
        if !open_less(h[c], h[p]) do break
        h[c], h[p] = h[p], h[c]
        c = p
    }
}

@(private)
heap_pop :: proc(h: ^[dynamic]Open) -> Open {
    root := h[0]
    last := pop(h)
    if len(h) == 0 do return root
    h[0] = last
    p := 0
    for {
        l, r := 2 * p + 1, 2 * p + 2
        s := p
        if l < len(h) && open_less(h[l], h[s]) do s = l
        if r < len(h) && open_less(h[r], h[s]) do s = r
        if s == p do break
        h[p], h[s] = h[s], h[p]
        p = s
    }
    return root
}

@(private)
Graph :: struct {
    m:      ^Map,
    offset: []i32, // per layer, its first node id
    total:  int,
}

@(private)
graph_make :: proc(m: ^Map) -> Graph {
    g := Graph{m = m, offset = make([]i32, len(m.layers) + 1, context.temp_allocator)}
    for l, i in m.layers do g.offset[i + 1] = g.offset[i] + i32(l.w * l.h)
    g.total = int(g.offset[len(m.layers)])
    return g
}

@(private)
node_id :: #force_inline proc(g: Graph, n: Node) -> i32 {
    l := &g.m.layers[n.layer]
    return g.offset[n.layer] + (n.y - i32(l.y)) * i32(l.w) + (n.x - i32(l.x))
}

@(private)
id_node :: proc(g: Graph, id: i32) -> Node {
    li := 0
    for g.offset[li + 1] <= id do li += 1
    l := &g.m.layers[li]
    k := id - g.offset[li]
    return Node{u16(li), i32(l.x) + k % i32(l.w), i32(l.y) + k / i32(l.w)}
}

// How long one metre of this cell takes, relative to open ground; 0 closed.
@(private)
cell_factor :: proc(m: ^Map, n: Node, agent: Agent) -> f32 {
    l := &m.layers[n.layer]
    i, ok := layer_cell(l, int(n.x), int(n.y))
    if !ok || l.height[i] == NO_FLOOR do return 0
    if l.surface[i] == .Deep do return 0
    if agent.guard && .No_Guards in l.flags[i] do return 0
    f := f32(1)
    if l.surface[i] == .Water do f = 2
    if .Crawl_Only in l.flags[i] do f = max(f, 2.5)
    return f
}

// Whether an agent fits at a node: every cell within its radius, in whole
// cells, has a floor within STEP of this one. A radius under a cell may
// overlap the cells beside it, so anyone can stand against a wall.
@(private)
fits :: proc(m: ^Map, n: Node, agent: Agent) -> bool {
    r := int(agent.radius / m.cell)
    if r <= 0 do return true
    h0, _ := height(m, n)
    for dy in -r ..= r {
        for dx in -r ..= r {
            if dx == 0 && dy == 0 do continue
            x, y := int(n.x) + dx, int(n.y) + dy
            if floor_near(m, x, y, h0) < 0 do return false
        }
    }
    return true
}

// The layer with a floor at cell (x, y) within STEP of h, -1 none; the
// closest one if several.
floor_near :: proc(m: ^Map, x, y: int, h: f32) -> int {
    best, best_d := -1, STEP + 0.001
    for li in layers_at(m, x, y) {
        fh, _ := height(m, Node{li, i32(x), i32(y)})
        d := abs(fh - h)
        if d < best_d {
            best, best_d = int(li), d
        }
    }
    return best
}

// Whether an agent can stand at a node.
standable :: proc(m: ^Map, n: Node, agent: Agent) -> bool {
    return cell_factor(m, n, agent) > 0 && fits(m, n, agent)
}

// The cheapest route from one node to another, walking and taking links.
// The result is allocated with `allocator`; free it with path_destroy.
find_path :: proc(m: ^Map, from, to: Node, agent: Agent, allocator := context.allocator) -> Path {
    if !standable(m, from, agent) || !standable(m, to, agent) do return {}
    speed := agent.speed if agent.speed > 0 else DEFAULT_SPEED

    g := graph_make(m)
    cost := make([]f32, g.total, context.temp_allocator)
    parent := make([]i32, g.total, context.temp_allocator)
    via := make([]i32, g.total, context.temp_allocator)
    closed := make([]bool, g.total, context.temp_allocator)
    for i in 0 ..< g.total {
        cost[i] = max(f32)
        parent[i] = -1
        via[i] = -1
    }

    // links by the node they leave from
    Out :: struct {
        link: i32,
        to:   Node,
        back: bool,
    }
    out_of := make(map[i32][dynamic]Out, allocator = context.temp_allocator)
    add_out :: proc(out_of: ^map[i32][dynamic]Out, from: i32, o: Out) {
        if from not_in out_of^ do out_of[from] = make([dynamic]Out, context.temp_allocator)
        append(&out_of[from], o)
    }
    for l, li in m.links {
        if !link_usable(l, agent) do continue
        a := Node{u16(l.a.layer), i32(l.a.x), i32(l.a.y)}
        b := Node{u16(l.b.layer), i32(l.b.x), i32(l.b.y)}
        if l.a.layer >= len(m.layers) || l.b.layer >= len(m.layers) do continue
        if !walkable(m, a) || !walkable(m, b) do continue
        add_out(&out_of, node_id(g, a), Out{i32(li), b, false})
        if l.kind != .Drop do add_out(&out_of, node_id(g, b), Out{i32(li), a, true})
    }

    target := node_id(g, to)
    tp := node_point(m, to)
    heuristic :: #force_inline proc(m: ^Map, n: Node, tp: [3]f32, speed: f32) -> f32 {
        p := cell_centre(m, int(n.x), int(n.y))
        return math.sqrt((p.x - tp.x) * (p.x - tp.x) + (p.y - tp.y) * (p.y - tp.y)) / speed
    }

    open := make([dynamic]Open, context.temp_allocator)
    start := node_id(g, from)
    cost[start] = 0
    heap_push(&open, Open{start, heuristic(m, from, tp, speed)})

    DIRS :: [8][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}

    found := false
    for len(open) > 0 {
        cur := heap_pop(&open)
        if closed[cur.node] do continue
        closed[cur.node] = true
        if cur.node == target {
            found = true
            break
        }
        n := id_node(g, cur.node)
        nh, _ := height(m, n)
        nf := cell_factor(m, n, agent)

        for d, k in DIRS {
            x, y := int(n.x + d.x), int(n.y + d.y)
            li := floor_near(m, x, y, nh)
            if li < 0 do continue
            nb := Node{u16(li), i32(x), i32(y)}
            bf := cell_factor(m, nb, agent)
            if bf == 0 || !fits(m, nb, agent) do continue
            step := m.cell
            if k >= 4 {
                // no corner cutting: both cells beside the diagonal open
                sa := floor_near(m, int(n.x + d.x), int(n.y), nh)
                sb := floor_near(m, int(n.x), int(n.y + d.y), nh)
                if sa < 0 || sb < 0 do continue
                if cell_factor(m, Node{u16(sa), n.x + d.x, n.y}, agent) == 0 do continue
                if cell_factor(m, Node{u16(sb), n.x, n.y + d.y}, agent) == 0 do continue
                step *= math.SQRT_TWO
            }
            id := node_id(g, nb)
            if closed[id] do continue
            nc := cost[cur.node] + step * 0.5 * (nf + bf) / speed
            if nc < cost[id] {
                cost[id] = nc
                parent[id] = cur.node
                via[id] = -1
                heap_push(&open, Open{id, nc + heuristic(m, nb, tp, speed)})
            }
        }

        if outs, has := out_of[cur.node]; has {
            for o in outs {
                if !standable(m, o.to, agent) do continue
                id := node_id(g, o.to)
                if closed[id] do continue
                l := m.links[o.link]
                // never cheaper than walking the same distance, so the
                // heuristic stays a lower bound
                a, b := node_point(m, n), node_point(m, o.to)
                flat := math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)) / speed
                nc := cost[cur.node] + max(link_cost(l), flat)
                if nc < cost[id] {
                    cost[id] = nc
                    parent[id] = cur.node
                    via[id] = o.link
                    heap_push(&open, Open{id, nc + heuristic(m, o.to, tp, speed)})
                }
            }
        }
    }
    if !found do return {}

    count := 0
    for id := target; id >= 0; id = parent[id] do count += 1
    p := Path{
        nodes = make([]Node, count, allocator),
        links = make([]int, count, allocator),
        cost  = cost[target],
        found = true,
    }
    i := count - 1
    for id := target; id >= 0; id = parent[id] {
        p.nodes[i] = id_node(g, id)
        p.links[i] = int(via[id])
        i -= 1
    }
    return p
}

// A link's cost in seconds: its own, or the kind's default when 0.
link_cost :: proc(l: Link) -> f32 {
    if l.cost > 0 do return l.cost
    return DEFAULT_LINK_COST[l.kind]
}

DEFAULT_LINK_COST := [Link_Kind]f32{
    .Stairs = 2,
    .Ladder = 4,
    .Door   = 1.5,
    .Window = 3,
    .Drop   = 1,
    .Climb  = 6,
}

DEFAULT_LINK_NOISE := [Link_Kind]f32{
    .Stairs = 3,
    .Ladder = 3,
    .Door   = 5,
    .Window = 8,
    .Drop   = 8,
    .Climb  = 4,
}

// The path's cells as map points (x, y, h), for following or drawing.
path_points :: proc(m: ^Map, p: Path, allocator := context.allocator) -> [][3]f32 {
    out := make([][3]f32, len(p.nodes), allocator)
    for n, i in p.nodes do out[i] = node_point(m, n)
    return out
}
