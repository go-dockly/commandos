
package nav

import "../mission"
import "../geom"

DIAGONAL_COST :: 1.41421356237

Path :: struct {
    points: []geom.Point,
    found: bool,
}

Node :: struct {
    index: int,
    cost: f32,
    score: f32,
}

nav_heap_less :: proc(a, b: Node) -> bool {
    if a.score != b.score {
        return a.score < b.score
    }
    return a.index < b.index
}

nav_heap_push :: proc(heap: ^[dynamic]Node, node: Node) {
    append(heap, node)
    child := len(heap^) - 1

    for child > 0 {
        parent := (child - 1) / 2
        if !nav_heap_less(heap[child], heap[parent]) do break
        heap[child], heap[parent] = heap[parent], heap[child]
        child = parent
    }
}

nav_heap_pop :: proc(heap: ^[dynamic]Node) -> Node {
    root := heap[0]
    last := pop(heap)

    if len(heap^) == 0 {
        return root
    }

    heap[0] = last
    parent := 0

    for {
        left := parent * 2 + 1
        right := left + 1
        smallest := parent

        if left < len(heap^) && nav_heap_less(heap[left], heap[smallest]) {
            smallest = left
        }
        if right < len(heap^) && nav_heap_less(heap[right], heap[smallest]) {
            smallest = right
        }
        if smallest == parent do break

        heap[parent], heap[smallest] = heap[smallest], heap[parent]
        parent = smallest
    }

    return root
}

nav_grid_dims :: proc(lvl: ^mission.Mission) -> (width: int, height: int) {
    bounds := mission.bounds(lvl)
    width = int(bounds.width)
    height = int(bounds.height)
    if width < 1 do width = 1
    if height < 1 do height = 1
    return
}

nav_index :: proc(x, y, grid_width: int) -> int {
    return y * grid_width + x
}

nav_in_bounds :: proc(x, y, grid_width, grid_height: int) -> bool {
    return x >= 0 && x < grid_width &&
           y >= 0 && y < grid_height
}

nav_cell_center :: proc(x, y: int) -> geom.Point {
    return geom.Point{x = f32(x) + 0.5, y = f32(y) + 0.5}
}

nav_heuristic :: proc(x, y, goal_x, goal_y: int) -> f32 {
    dx := abs(goal_x - x)
    dy := abs(goal_y - y)
    diagonal := min(dx, dy)
    straight := max(dx, dy) - diagonal
    return f32(diagonal) * DIAGONAL_COST + f32(straight)
}

find_path :: proc(
    level: ^mission.Mission,
    start: geom.Point,
    goal: geom.Point,
    radius: f32,
) -> Path {
    result := Path{}
    grid_w, grid_h := nav_grid_dims(level)
    cell_count := grid_w * grid_h

    if start.x < 0 || start.x >= f32(grid_w) ||
       start.y < 0 || start.y >= f32(grid_h) ||
       goal.x < 0 || goal.x >= f32(grid_w) ||
       goal.y < 0 || goal.y >= f32(grid_h) {
        return result
    }

    start_x := int(start.x)
    start_y := int(start.y)
    goal_x := int(goal.x)
    goal_y := int(goal.y)

    if !nav_in_bounds(start_x, start_y, grid_w, grid_h) ||
       !nav_in_bounds(goal_x, goal_y, grid_w, grid_h) {
        return result
    }

    if mission.point_collides(level, start, radius) ||
       mission.point_collides(level, goal, radius) {
        return result
    }

    start_idx := nav_index(start_x, start_y, grid_w)
    goal_idx := nav_index(goal_x, goal_y, grid_w)

    costs := make([]f32, cell_count)
    defer delete(costs)

    parents := make([]int, cell_count)
    defer delete(parents)

    closed := make([]bool, cell_count)
    defer delete(closed)

    for i in 0..<cell_count {
        costs[i] = 1e30
        parents[i] = -1
    }

    open_heap: [dynamic]Node
    defer delete(open_heap)

    costs[start_idx] = 0
    nav_heap_push(&open_heap, Node{
        index = start_idx,
        cost = 0,
        score = nav_heuristic(start_x, start_y, goal_x, goal_y),
    })

    offsets := [8][2]int{
        {-1,  0}, { 1,  0}, { 0, -1}, { 0,  1},
        {-1, -1}, { 1, -1}, {-1,  1}, { 1,  1},
    }

    for len(open_heap) > 0 {
        entry := nav_heap_pop(&open_heap)
        current_idx := entry.index

        if entry.cost != costs[current_idx] || closed[current_idx] {
            continue
        }

        if current_idx == goal_idx {
            reverse_path := make([dynamic]geom.Point)
            defer delete(reverse_path)

            current := current_idx
            for current >= 0 {
                append(&reverse_path, nav_cell_center(current % grid_w, current / grid_w))
                current = parents[current]
            }

            result.points = make([]geom.Point, len(reverse_path))
            for i in 0..<len(reverse_path) {
                result.points[i] = reverse_path[len(reverse_path)-1-i]
            }

            if len(result.points) > 0 {
                result.points[0] = start
            }

            result.found = true
            return result
        }

        closed[current_idx] = true
        current_x := current_idx % grid_w
        current_y := current_idx / grid_w

        for offset in offsets {
            dx := offset[0]
            dy := offset[1]
            next_x := current_x + dx
            next_y := current_y + dy

            if !nav_in_bounds(next_x, next_y, grid_w, grid_h) do continue

            next_idx := nav_index(next_x, next_y, grid_w)
            if closed[next_idx] do continue

            next_point := nav_cell_center(next_x, next_y)
            if mission.point_collides(level, next_point, radius) {
                continue
            }

            if dx != 0 && dy != 0 {
                side_x := nav_cell_center(current_x + dx, current_y)
                side_y := nav_cell_center(current_x, current_y + dy)

                if mission.point_collides(level, side_x, radius) ||
                   mission.point_collides(level, side_y, radius) {
                    continue
                }
            }

            move_cost := f32(1)
            if dx != 0 && dy != 0 {
                move_cost = DIAGONAL_COST
            }

            tentative_cost := costs[current_idx] + move_cost

            if tentative_cost < costs[next_idx] {
                costs[next_idx] = tentative_cost
                parents[next_idx] = current_idx

                h := nav_heuristic(next_x, next_y, goal_x, goal_y)
                nav_heap_push(&open_heap, Node{
                    index = next_idx,
                    cost = tentative_cost,
                    score = tentative_cost + h,
                })
            }
        }
    }

    return result
}
