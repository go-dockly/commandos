
package nav

import "core:testing"
import "../geom"
import "../mission"

@(test)
test_navigation_finds_direct_path :: proc(t: ^testing.T) {
    level := mission.Mission{}

    path := find_path(
        &level,
        {10.5, 10.5},
        {15.5, 15.5},
        0.0,
    )
    defer delete(path.points)

    testing.expect(t, path.found)
    testing.expect(t, len(path.points) > 0)
    testing.expect(t, path.points[0].x == 10.5)
    testing.expect(t, path.points[len(path.points)-1].x == 15.5)
    testing.expect(t, path.points[len(path.points)-1].y == 15.5)
}

@(test)
test_navigation_routes_around_building :: proc(t: ^testing.T) {
    level := mission.Mission{
        buildings = {
            geom.Rect{
                x = 12,
                y = 10,
                w = 5,
                h = 5,
            },
        },
    }

    path := find_path(
        &level,
        {10.5, 12.5},
        {18.5, 12.5},
        0.01,
    )
    defer delete(path.points)

    testing.expect(t, path.found)

    for point in path.points {
        testing.expect(t, !mission.point_collides(&level, point, 0.01))
    }
}

@(test)
test_navigation_does_not_cut_diagonal_corners :: proc(t: ^testing.T) {
    level := mission.Mission{
        cover = {
            geom.Cover{
                kind = "crate",
                x = 11,
                y = 10,
                w = 1,
                h = 1,
            },
            geom.Cover{
                kind = "crate",
                x = 10,
                y = 11,
                w = 1,
                h = 1,
            },
        },
    }

    path := find_path(
        &level,
        {10.5, 10.5},
        {11.5, 11.5},
        0.01,
    )
    defer delete(path.points)

    testing.expect(t, path.found)
    testing.expect(t, len(path.points) > 2)
}

@(test)
test_navigation_rejects_blocked_goal :: proc(t: ^testing.T) {
    level := mission.Mission{
        buildings = {
            geom.Rect{
                x = 20,
                y = 20,
                w = 2,
                h = 2,
            },
        },
    }

    path := find_path(
        &level,
        {10.5, 10.5},
        {20.5, 20.5},
        0.01,
    )
    defer delete(path.points)

    testing.expect(t, !path.found)
    testing.expect(t, len(path.points) == 0)
}

@(test)
test_navigation_rejects_out_of_bounds_positions :: proc(t: ^testing.T) {
    level := mission.Mission{}

    path := find_path(
        &level,
        {-1, 10},
        {10, 10},
        0.0,
    )
    defer delete(path.points)

    testing.expect(t, !path.found)
}
