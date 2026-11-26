package gamemap

// The map files:
//
//   krakow.map.json  format and version, frame, cell, grid size, layer
//                    windows, features, links, interiors: what a person
//                    reads and diffs
//   krakow.map.bin   the grids, little-endian:
//                      "CMAP", u32 version, u32 maps (the map, then each interior)
//                      per map: u32 w, h, layers
//                        per layer: u32 x, y, w, h; i16 height[n] (cm),
//                                   u8 surface[n], u8 cover[n], u8 flags[n]
//                        i16 spans[w * h * 2 * 2] (bottom, top, bottom, top; cm)
//
// A reader refuses a newer version.

import "core:encoding/endian"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

Error :: enum {
    None,
    Read,
    Write,
    Json,
    Format,
    Version, // newer than this reader
    Bin,     // missing, short or not matching the JSON
}

BIN_MAGIC :: "CMAP"

File_Layer :: struct {
    name: string `json:"name"`,
    x:    int    `json:"x"`,
    y:    int    `json:"y"`,
    w:    int    `json:"w"`,
    h:    int    `json:"h"`,
}

File_Interior :: struct {
    id:       string       `json:"id"`,
    building: string       `json:"building"`,
    cell:     f32          `json:"cell"`,
    w:        int          `json:"w"`,
    h:        int          `json:"h"`,
    layers:   []File_Layer `json:"layers"`,
    links:    []Link       `json:"links"`,
}

File :: struct {
    format:    string          `json:"format"`,
    version:   int             `json:"version"`,
    bin:       string          `json:"bin"`,
    frame:     Frame           `json:"frame"`,
    cell:      f32             `json:"cell"`,
    w:         int             `json:"w"`,
    h:         int             `json:"h"`,
    layers:    []File_Layer    `json:"layers"`,
    features:  []Feature       `json:"features"`,
    links:     []Link          `json:"links"`,
    interiors: []File_Interior `json:"interiors"`,
}

// The binary file next to a map's JSON: krakow.map.json -> krakow.map.bin.
bin_path :: proc(json_path: string, allocator := context.allocator) -> string {
    base := strings.trim_suffix(json_path, ".json")
    return strings.concatenate({base, ".bin"}, allocator)
}

save :: proc(m: Map, json_path: string) -> Error {
    m := m
    bp := bin_path(json_path, context.temp_allocator)

    file := File{
        format = FORMAT, version = VERSION,
        bin = filepath.base(bp),
        frame = m.frame, cell = m.cell, w = m.w, h = m.h,
        layers = file_layers(&m),
        features = m.features[:],
        links = m.links[:],
        interiors = make([]File_Interior, len(m.interiors), context.temp_allocator),
    }
    for &inner, i in m.interiors {
        file.interiors[i] = File_Interior{
            id = inner.id, building = inner.building, cell = inner.m.cell, w = inner.m.w, h = inner.m.h,
            layers = file_layers(&inner.m), links = inner.m.links[:],
        }
    }
    text, merr := json.marshal(file, {pretty = true, use_enum_names = true}, context.temp_allocator)
    if merr != nil do return .Json

    buf := make([dynamic]byte, context.temp_allocator)
    append(&buf, BIN_MAGIC)
    put_u32(&buf, VERSION)
    put_u32(&buf, u32(1 + len(m.interiors)))
    write_grids(&buf, &m)
    for &inner in m.interiors do write_grids(&buf, &inner.m)

    if write_atomic(bp, buf[:]) != nil do return .Write
    if write_atomic(json_path, text) != nil do return .Write
    return .None
}

// Reads a map's JSON and the binary file it names. The map owns everything
// it holds; free it with destroy.
load :: proc(json_path: string) -> (m: Map, err: Error) {
    data, rerr := os.read_entire_file(json_path, context.temp_allocator)
    if rerr != nil do return {}, .Read

    file: File
    if json.unmarshal(data, &file, allocator = context.temp_allocator) != nil do return {}, .Json
    if file.format != FORMAT do return {}, .Format
    if file.version > VERSION || file.version < 1 do return {}, .Version
    if file.w <= 0 || file.h <= 0 || len(file.layers) == 0 do return {}, .Format

    bp := file.bin if file.bin != "" else filepath.base(bin_path(json_path, context.temp_allocator))
    if !filepath.is_abs(bp) do bp, _ = filepath.join({filepath.dir(json_path), bp}, context.temp_allocator)
    bin, berr := os.read_entire_file(bp, context.temp_allocator)
    if berr != nil do return {}, .Bin
    if len(bin) < 12 || string(bin[:4]) != BIN_MAGIC do return {}, .Bin
    r := Reader{bin, 4, true}
    if get_u32(&r) > VERSION do return {}, .Version
    if int(get_u32(&r)) != 1 + len(file.interiors) do return {}, .Bin

    m = make_map(file.frame, file.cell, file.w, file.h)
    defer if err != .None do destroy(&m)
    if !read_grids(&r, &m, file.layers) do return m, .Bin
    for f in file.features do append(&m.features, clone_feature(&m, f))
    for l in file.links do append(&m.links, clone_link(&m, l))
    for fi in file.interiors {
        inner := init_map(m.allocator, {}, fi.cell, fi.w, fi.h)
        if !read_grids(&r, &inner, fi.layers) do return m, .Bin
        for l in fi.links do append(&inner.links, clone_link(&m, l))
        reindex(&inner)
        inner.stamped = true
        append(&m.interiors, Interior{id = clone(&m, fi.id), building = clone(&m, fi.building), m = inner})
    }
    reindex(&m)
    m.stamped = true
    return m, .None
}

@(private)
file_layers :: proc(m: ^Map) -> []File_Layer {
    out := make([]File_Layer, len(m.layers), context.temp_allocator)
    for l, i in m.layers do out[i] = {l.name, l.x, l.y, l.w, l.h}
    return out
}

@(private)
clone_feature :: proc(m: ^Map, f: Feature) -> Feature {
    out := f
    out.id = clone(m, f.id)
    out.footprint = make([][][2]f32, len(f.footprint), m.allocator)
    for ring, i in f.footprint do out.footprint[i] = clone_ring(m, ring)
    return out
}

@(private)
clone_link :: proc(m: ^Map, l: Link) -> Link {
    out := l
    out.id = clone(m, l.id)
    out.a.interior = clone(m, l.a.interior)
    out.b.interior = clone(m, l.b.interior)
    return out
}

// ---------------------------------------------------------------------------
// Binary
// ---------------------------------------------------------------------------

@(private)
put_u32 :: proc(buf: ^[dynamic]byte, v: u32) {
    b: [4]byte
    endian.put_u32(b[:], .Little, v)
    append(buf, ..b[:])
}

@(private)
put_i16 :: proc(buf: ^[dynamic]byte, v: i16) {
    b: [2]byte
    endian.put_i16(b[:], .Little, v)
    append(buf, ..b[:])
}

@(private)
write_grids :: proc(buf: ^[dynamic]byte, m: ^Map) {
    put_u32(buf, u32(m.w))
    put_u32(buf, u32(m.h))
    put_u32(buf, u32(len(m.layers)))
    for l in m.layers {
        put_u32(buf, u32(l.x))
        put_u32(buf, u32(l.y))
        put_u32(buf, u32(l.w))
        put_u32(buf, u32(l.h))
        for v in l.height do put_i16(buf, v)
        for v in l.surface do append(buf, u8(v))
        for v in l.cover do append(buf, u8(v))
        for v in l.flags do append(buf, transmute(u8)v)
    }
    for s in m.spans {
        for e in s {
            put_i16(buf, e.bottom)
            put_i16(buf, e.top)
        }
    }
}

@(private)
Reader :: struct {
    b:   []byte,
    at:  int,
    ok:  bool,
}

@(private)
get_u32 :: proc(r: ^Reader) -> u32 {
    if r.at + 4 > len(r.b) {
        r.ok = false
        return 0
    }
    v, _ := endian.get_u32(r.b[r.at:r.at + 4], .Little)
    r.at += 4
    return v
}

@(private)
get_i16 :: proc(r: ^Reader) -> i16 {
    if r.at + 2 > len(r.b) {
        r.ok = false
        return 0
    }
    v, _ := endian.get_i16(r.b[r.at:r.at + 2], .Little)
    r.at += 2
    return v
}

@(private)
get_u8 :: proc(r: ^Reader) -> u8 {
    if r.at + 1 > len(r.b) {
        r.ok = false
        return 0
    }
    r.at += 1
    return r.b[r.at - 1]
}

// Reads one map's grids into m, which has its ground layer already; the
// windows must match the JSON's.
@(private)
read_grids :: proc(r: ^Reader, m: ^Map, layers: []File_Layer) -> bool {
    if int(get_u32(r)) != m.w || int(get_u32(r)) != m.h do return false
    if int(get_u32(r)) != len(layers) do return false
    for fl, li in layers {
        x, y, w, h := int(get_u32(r)), int(get_u32(r)), int(get_u32(r)), int(get_u32(r))
        if !r.ok || x != fl.x || y != fl.y || w != fl.w || h != fl.h do return false
        if x < 0 || y < 0 || x + w > m.w || y + h > m.h do return false
        if li == 0 && (x != 0 || y != 0 || w != m.w || h != m.h) do return false
        idx := 0
        if li == 0 {
            m.layers[0].name = clone(m, fl.name)
        } else {
            idx = add_layer(m, fl.name, x, y, w, h)
        }
        l := &m.layers[idx]
        for &v in l.height do v = get_i16(r)
        for &v in l.surface {
            s := get_u8(r)
            v = Surface(s) if s <= u8(max(Surface)) else .Deep
        }
        for &v in l.cover {
            c := get_u8(r)
            v = Cover(c) if c <= u8(max(Cover)) else .None
        }
        for &v in l.flags do v = transmute(Flags)get_u8(r)
        if !r.ok do return false
    }
    for &s in m.spans {
        for &e in s {
            e.bottom = get_i16(r)
            e.top = get_i16(r)
        }
    }
    return r.ok
}

// Writes through a temporary file, so a crash leaves the old file whole.
@(private)
write_atomic :: proc(path: string, data: []byte) -> os.Error {
    tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
    os.write_entire_file(tmp, data) or_return
    return os.rename(tmp, path)
}
