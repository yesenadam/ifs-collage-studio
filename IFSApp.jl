import CImGui as ig
import ModernGL as GL
import GLFW
using PNGFiles, ColorTypes, FixedPointNumbers, Dates, TOML
ig.set_backend(:GlfwOpenGL3)

mutable struct AffineCopy
    tx::Float64; ty::Float64
    sx::Float64; sy::Float64
    angle::Float64
    shx::Float64; shy::Float64
    bx::Float64;  by::Float64
    rgb::Vector{Float32}
end

mutable struct IFSAccumulator
    hits::Matrix{Int}
    r_sum::Matrix{Float32}
    g_sum::Matrix{Float32}
    b_sum::Matrix{Float32}
    x::Float64; y::Float64
    cr::Float32; cg::Float32; cb::Float32
    total_dots::Int
end

IFSAccumulator(w::Int, h::Int) = IFSAccumulator(zeros(Int, w, h), zeros(Float32, w, h), zeros(Float32, w, h),
                                                zeros(Float32, w, h), 0.0, 0.0, 1.0f0, 1.0f0, 1.0f0, 0)

function reset_acc!(acc::IFSAccumulator)
    fill!(acc.hits, 0); fill!(acc.r_sum, 0.0f0); fill!(acc.g_sum, 0.0f0); fill!(acc.b_sum, 0.0f0)
    acc.x = 0.0; acc.y = 0.0; acc.cr = 1.0f0; acc.cg = 1.0f0; acc.cb = 1.0f0
    acc.total_dots = 0
end

# 13 distinct colours for up to 13 maps
const INIT_COLS = [
    Float32[0.93, 0.20, 0.20], Float32[0.15, 0.55, 0.95], Float32[0.15, 0.75, 0.25],
    Float32[0.95, 0.60, 0.05], Float32[0.75, 0.20, 0.85], Float32[0.05, 0.75, 0.75],
    Float32[0.95, 0.35, 0.60], Float32[0.60, 0.45, 0.25], Float32[0.75, 0.75, 0.15],
    Float32[0.45, 0.45, 0.95], Float32[0.10, 0.50, 0.35], Float32[0.85, 0.30, 0.10],
    Float32[0.50, 0.20, 0.60]
]

make_str_buf(len::Int = 128) = zeros(UInt8, len)
function read_str_buf(buf::Vector{UInt8})
    z = findfirst(==(0x00), buf)
    return strip(String(buf[1:(z === nothing ? end : z - 1)]))
end

function load_serif_font!(size_px::Float32 = 18.0f0)
    io = ig.GetIO()
    fonts = unsafe_load(io).Fonts
    candidates = [
        "/System/Library/Fonts/Supplemental/Georgia.ttf",
        "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
        "/System/Library/Fonts/Palatino.ttc",
        "/Library/Fonts/Georgia.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf",
        "C:\\Windows\\Fonts\\georgia.ttf"
    ]
    for path in candidates
        if isfile(path)
            ig.ImFontAtlas_AddFontFromFileTTF(fonts, path, size_px, C_NULL, C_NULL)
            return
        end
    end
end

function rgb_to_abgr(rgb)
    r, g, b = rgb
    ri = UInt32(round(Int, clamp(r, 0, 1) * 255))
    gi = UInt32(round(Int, clamp(g, 0, 1) * 255))
    bi = UInt32(round(Int, clamp(b, 0, 1) * 255))
    return 0xFF000000 | (bi << 16) | (gi << 8) | ri
end

function get_matrix(m::AffineCopy)
    ca, sa = cos(m.angle), sin(m.angle)
    m11, m12 = m.sx, m.sy * m.shx
    m21, m22 = m.sx * m.shy, m.sy
    return (ca*m11 - sa*m21, ca*m12 - sa*m22, m.tx,
            sa*m11 + ca*m21, sa*m12 + ca*m22, m.ty, m.bx, m.by)
end

@inline function apply_map(mat, x::Float64, y::Float64)
    a, b, tx, c, d, ty, bx, by = mat
    return a*x + b*y + tx + bx*y*y, c*x + d*y + ty + by*x*x
end

function paint_line!(pxs, p0, x1, y1, r, col)
    x0, y0 = p0
    steps = max(abs(x1 - x0), abs(y1 - y0), 1)
    w, h = size(pxs)
    for i in 0:steps
        cx = round(Int, x0 + (i / steps) * (x1 - x0))
        cy = round(Int, y0 + (i / steps) * (y1 - y0))
        for dy in -r:r, dx in -r:r
            (dx*dx + dy*dy <= r*r && 1 <= cx+dx <= w && 1 <= cy+dy <= h) && (pxs[cx+dx, cy+dy] = col)
        end
    end
end

function render_seed!(disp_pxs, base_pxs, pts, copies, sel, seed_bg, tex1)
    w, h = size(disp_pxs)
    bg_u32 = rgb_to_abgr(seed_bg)
    ink_u32 = sum(seed_bg) < 1.2f0 ? 0xFFFFFFFF : 0xFF000000
    for i in eachindex(disp_pxs)
        disp_pxs[i] = base_pxs[i] ? ink_u32 : bg_u32
    end

    # Draw all coloured map copies
    for (i, m) in enumerate(copies)
        mat = get_matrix(m)
        col = rgb_to_abgr(m.rgb)
        for (x, y) in pts
            nx, ny = apply_map(mat, x, y)
            px = round(Int, (nx + 1.0) * 0.5 * (w - 1)) + 1
            py = round(Int, (ny + 1.0) * 0.5 * (h - 1)) + 1
            if 1 <= px <= w && 1 <= py <= h
                disp_pxs[px, py] = col
                (i == sel && px < w) && (disp_pxs[px + 1, py] = col)
            end
        end
    end

    # Draw warped bounding outline around the currently selected map
    if 1 <= sel <= length(copies)
        m = copies[sel]
        mat = get_matrix(m)
        box_col = rgb_to_abgr(m.rgb)
        for t in -1.0:0.004:1.0
            for (bx, by) in ((t, -1.0), (t, 1.0), (-1.0, t), (1.0, t))
                nx, ny = apply_map(mat, bx, by)
                px = round(Int, (nx + 1.0) * 0.5 * (w - 1)) + 1
                py = round(Int, (ny + 1.0) * 0.5 * (h - 1)) + 1
                (1 <= px <= w && 1 <= py <= h) && (disp_pxs[px, py] = box_col)
            end
        end
    end

    upload_tex!(tex1, disp_pxs)
end

function accumulate_dots!(acc::IFSAccumulator, copies, prob_mode, out_sx, out_sy, out_ox, out_oy, batch_size::Int)
    isempty(copies) && return
    ow, oh = size(acc.hits)
    mats = [get_matrix(m) for m in copies]
    n = length(mats)
    weights = prob_mode == 1 ? fill(1.0 / n, n) : [max(0.02, abs(m.sx * m.sy)) for m in copies]
    cum_w = cumsum(weights) ./ sum(weights)

    x, y = acc.x, acc.y
    cr, cg, cb = acc.cr, acc.cg, acc.cb
    is_first_batch = (acc.total_dots == 0)

    for i in 1:batch_size
        idx = findfirst(>=(rand()), cum_w)
        x, y = apply_map(mats[idx], x, y)
        if abs(x) > 10.0 || abs(y) > 10.0
            x = y = 0.0; continue
        end
        mr, mg, mb = copies[idx].rgb
        cr = 0.5f0 * (cr + mr); cg = 0.5f0 * (cg + mg); cb = 0.5f0 * (cb + mb)

        if !is_first_batch || i > 20
            px = round(Int, (x * out_sx + out_ox + 1.0) * 0.5 * (ow - 1)) + 1
            py = round(Int, (y * out_sy + out_oy + 1.0) * 0.5 * (oh - 1)) + 1
            if 1 <= px <= ow && 1 <= py <= oh
                acc.hits[px, py] += 1
                acc.r_sum[px, py] += cr; acc.g_sum[px, py] += cg; acc.b_sum[px, py] += cb
            end
        end
    end
    acc.x, acc.y = x, y; acc.cr, acc.cg, acc.cb = cr, cg, cb
    acc.total_dots += batch_size
end

function tone_map_output!(out_pxs, acc::IFSAccumulator, copies, col_mode, custom_rgb, out_bg, norm_on, eq_on, tex2)
    ow, oh = size(out_pxs)
    fill!(out_pxs, rgb_to_abgr(out_bg))
    (isempty(copies) || acc.total_dots == 0) && return upload_tex!(tex2, out_pxs)

    max_h = maximum(acc.hits)
    max_h == 0 && return upload_tex!(tex2, out_pxs)

    eq_lut = Float32[]
    if eq_on
        nz = sort!(vec(acc.hits[acc.hits .> 0]))
        eq_lut = zeros(Float32, max_h)
        for (rank, val) in enumerate(nz)
            eq_lut[val] = Float32(rank) / length(nz)
        end
    end

    br, bg_c, bb = col_mode == 1 ? (1.0f0, 1.0f0, 1.0f0) :
                   col_mode == 2 ? (0.2f0, 1.0f0, 0.3f0) :
                   col_mode == 3 ? (1.0f0, 0.25f0, 0.25f0) :
                   col_mode == 4 ? (0.3f0, 0.6f0, 1.0f0) : Tuple(custom_rgb)
    obr, obg, obb = out_bg
    inv_log_max = 1.0f0 / log1p(Float32(max_h))

    for py in 1:oh, px in 1:ow
        h = acc.hits[px, py]
        h == 0 && continue
        t = eq_on   ? eq_lut[h] :
            norm_on ? log1p(Float32(h)) * inv_log_max : 1.0f0
        t = clamp(0.15f0 + 0.85f0 * t, 0.0f0, 1.0f0)

        if col_mode == 6
            tr = (acc.r_sum[px, py] / h) * t
            tg = (acc.g_sum[px, py] / h) * t
            tb = (acc.b_sum[px, py] / h) * t
        else
            tr, tg, tb = br * t, bg_c * t, bb * t
        end
        out_pxs[px, py] = rgb_to_abgr((obr * (1 - t) + tr, obg * (1 - t) + tg, obb * (1 - t) + tb))
    end
    upload_tex!(tex2, out_pxs)
end

function save_output_png(out_pxs::Matrix{UInt32}, raw_name::AbstractString)
    w, h = size(out_pxs)
    img = Matrix{RGB{N0f8}}(undef, h, w)
    for y in 1:h, x in 1:w
        c = out_pxs[x, y]
        r = reinterpret(N0f8, UInt8(c & 0xFF))
        g = reinterpret(N0f8, UInt8((c >> 8) & 0xFF))
        b = reinterpret(N0f8, UInt8((c >> 16) & 0xFF))
        img[y, x] = RGB{N0f8}(r, g, b)
    end
    base = isempty(raw_name) ? "ifs_$(Dates.format(now(), "yyyy-mm-dd_HHMMSS"))" : raw_name
    fname = endswith(lowercase(base), ".png") ? base : base * ".png"
    PNGFiles.save(fname, img)
    return fname
end

function save_ifs_toml(raw_name::AbstractString, base_pxs::BitMatrix, copies, prob_mode, col_mode,
                       custom_rgb, seed_bg, out_bg, out_sx, out_sy, out_ox, out_oy, norm_on, eq_on)
    w, h = size(base_pxs)
    drawn_coords = [[x, y] for y in 1:h for x in 1:w if base_pxs[x, y]]

    data = Dict(
        "settings" => Dict(
            "prob_mode" => Int(prob_mode), "col_mode" => Int(col_mode),
            "custom_rgb" => Float64.(custom_rgb),
            "seed_bg" => Float64.(seed_bg), "out_bg" => Float64.(out_bg),
            "out_sx" => Float64(out_sx), "out_sy" => Float64(out_sy),
            "out_ox" => Float64(out_ox), "out_oy" => Float64(out_oy),
            "norm_on" => norm_on, "eq_on" => eq_on
        ),
        "seed" => Dict("width" => w, "height" => h, "pixels" => drawn_coords),
        "maps" => [
            Dict("tx" => m.tx, "ty" => m.ty, "sx" => m.sx, "sy" => m.sy,
                 "angle" => m.angle, "shx" => m.shx, "shy" => m.shy,
                 "bx" => m.bx, "by" => m.by, "rgb" => Float64.(m.rgb))
            for m in copies
        ]
    )
    base = isempty(raw_name) ? "preset_$(Dates.format(now(), "yyyy-mm-dd_HHMMSS"))" : raw_name
    fname = endswith(lowercase(base), ".toml") ? base : base * ".toml"
    open(fname, "w") do io
        TOML.print(io, data)
    end
    return fname
end

function load_ifs_toml!(fname, base_pxs::BitMatrix, pts, copies, prob_mode, col_mode,
                        custom_rgb, seed_bg, out_bg, out_sx, out_sy, out_ox, out_oy, norm_on, eq_on)
    data = TOML.parsefile(fname)
    s = data["settings"]
    prob_mode[] = Cint(s["prob_mode"]); col_mode[] = Cint(s["col_mode"])
    copyto!(custom_rgb, Float32.(s["custom_rgb"]))
    haskey(s, "seed_bg") && copyto!(seed_bg, Float32.(s["seed_bg"]))
    copyto!(out_bg, Float32.(s["out_bg"]))
    out_sx[] = Float32(s["out_sx"]); out_sy[] = Float32(s["out_sy"])
    out_ox[] = Float32(get(s, "out_ox", 0.0)); out_oy[] = Float32(get(s, "out_oy", 0.0))
    norm_on[] = s["norm_on"]; eq_on[] = s["eq_on"]

    fill!(base_pxs, false)
    empty!(pts)
    w, h = size(base_pxs)

    if haskey(data, "seed") && haskey(data["seed"], "pixels") && !isempty(data["seed"]["pixels"])
        sw = get(data["seed"], "width", w)
        sh = get(data["seed"], "height", h)
        for pair in data["seed"]["pixels"]
            px, py = pair
            x = clamp(round(Int, (px - 1) / max(1, sw - 1) * (w - 1)) + 1, 1, w)
            y = clamp(round(Int, (py - 1) / max(1, sh - 1) * (h - 1)) + 1, 1, h)
            base_pxs[x, y] = true
        end
        for y in 1:h, x in 1:w
            base_pxs[x, y] && push!(pts, ((x - 1) / (w - 1) * 2 - 1, (y - 1) / (h - 1) * 2 - 1))
        end
    else
        for t in -1.0:0.02:1.0
            push!(pts, (t, -1.0), (t, 1.0), (-1.0, t), (1.0, t))
        end
    end

    empty!(copies)
    for md in data["maps"]
        push!(copies, AffineCopy(md["tx"], md["ty"], md["sx"], md["sy"], md["angle"],
                                 md["shx"], md["shy"], md["bx"], md["by"], Float32.(md["rgb"])))
    end
end

function main()
    W, OUT = 530, 800
    base_pxs = falses(W, W)
    disp_pxs = fill(0xFFFFFFFF, W, W)
    out_pxs  = fill(0xFF000000, OUT, OUT)
    acc      = IFSAccumulator(OUT, OUT)

    pts, copies = Tuple{Float64, Float64}[], AffineCopy[]
    locked, sel, brush = Ref(false), Ref(0), Ref(Cint(1))
    last_p = Ref{Union{Nothing, Tuple{Int, Int}}}(nothing)
    t1 = t2 = GL.GLuint(0)

    prob_mode  = Ref(Cint(2))
    col_mode   = Ref(Cint(1))
    custom_rgb = Float32[1.0, 0.85, 0.2]
    seed_bg    = Float32[1.0, 1.0, 1.0]
    out_bg     = Float32[0.0, 0.0, 0.0]
    out_sx     = Ref(1.0f0)
    out_sy     = Ref(1.0f0)
    out_ox     = Ref(0.0f0)
    out_oy     = Ref(0.0f0)
    norm_on    = Ref(true)
    eq_on      = Ref(false)
    max_dots   = Ref(Cint(1_500_000))
    status_msg = Ref("")
    preset_files = Ref(String[])

    name_buf  = make_str_buf(128)
    save_kind = Ref(:none)

    ctx = ig.CreateContext()
    load_serif_font!(18.0f0)

    ig.render(ctx; window_size=(1480, 920), window_title="IFS Collage Studio") do
        win = GLFW.GetCurrentContext()
        if t1 == 0
            GLFW.MaximizeWindow(win)
            t1, t2 = make_tex(disp_pxs), make_tex(out_pxs)
            render_seed!(disp_pxs, base_pxs, pts, copies, sel[], seed_bg, t1)
        end
        ww, wh = GLFW.GetWindowSize(win)
        hw, fh = Float32(ww ÷ 2), Float32(wh)
        flags = ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoResize
        dirty_seed   = false
        reset_dots   = false
        recolor_only = false

        typing = (save_kind[] != :none)

        if !typing && ig.IsKeyPressed(ig.ImGuiKey_Space, false)
            if !locked[]
                for y in 1:W, x in 1:W
                    base_pxs[x, y] && push!(pts, ((x-1)/(W-1)*2-1, (y-1)/(W-1)*2-1))
                end
                locked[] = !isempty(pts)
            end
            if locked[] && length(copies) < 13
                i = length(copies) + 1
                off = (i - 1) * 0.06 - 0.25
                push!(copies, AffineCopy(off, off, 0.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, copy(INIT_COLS[i])))
                sel[] = i; dirty_seed = reset_dots = true
            end
        end
                # Cycle through maps with Tab (and Shift+Tab backwards)
        if !typing && locked[] && !isempty(copies) && ig.IsKeyPressed(ig.ImGuiKey_Tab, false)
            if ig.IsKeyDown(ig.ImGuiKey_LeftShift) || ig.IsKeyDown(ig.ImGuiKey_RightShift)
                sel[] = sel[] <= 1 ? length(copies) : sel[] - 1
            else
                sel[] = sel[] >= length(copies) ? 1 : sel[] + 1
            end
            dirty_seed = true
        end

        if !typing && locked[] && 1 <= sel[] <= length(copies)
            m = copies[sel[]]
            if ig.IsKeyPressed(ig.ImGuiKey_F, false)
                m.sx = -m.sx
                m.angle = -m.angle
                m.bx = -m.bx
                dirty_seed = reset_dots = true
            end
            if ig.IsKeyPressed(ig.ImGuiKey_G, false)
                m.sy = -m.sy
                m.angle = -m.angle
                m.by = -m.by
                dirty_seed = reset_dots = true
            end

            cmd   = ig.IsKeyDown(ig.ImGuiKey_LeftCtrl) || ig.IsKeyDown(ig.ImGuiKey_RightCtrl) ||
                    ig.IsKeyDown(ig.ImGuiKey_LeftSuper) || ig.IsKeyDown(ig.ImGuiKey_RightSuper)
            opt   = ig.IsKeyDown(ig.ImGuiKey_LeftAlt)   || ig.IsKeyDown(ig.ImGuiKey_RightAlt)
            shift = ig.IsKeyDown(ig.ImGuiKey_LeftShift) || ig.IsKeyDown(ig.ImGuiKey_RightShift)
            L, R = ig.IsKeyDown(ig.ImGuiKey_LeftArrow), ig.IsKeyDown(ig.ImGuiKey_RightArrow)
            U, D = ig.IsKeyDown(ig.ImGuiKey_UpArrow),   ig.IsKeyDown(ig.ImGuiKey_DownArrow)

            if shift && opt
                # Unbounded quadratic bending
                L && (m.bx -= 0.005; dirty_seed = reset_dots = true)
                R && (m.bx += 0.005; dirty_seed = reset_dots = true)
                U && (m.by -= 0.005; dirty_seed = reset_dots = true)
                D && (m.by += 0.005; dirty_seed = reset_dots = true)
            elseif shift
                L && (m.shx = max(-1.5, m.shx - 0.015); dirty_seed = reset_dots = true)
                R && (m.shx = min(1.5,  m.shx + 0.015); dirty_seed = reset_dots = true)
                U && (m.shy = max(-1.5, m.shy - 0.015); dirty_seed = reset_dots = true)
                D && (m.shy = min(1.5,  m.shy + 0.015); dirty_seed = reset_dots = true)
            elseif opt
                L && (m.sx = max(-1.2, m.sx - 0.01); dirty_seed = reset_dots = true)
                R && (m.sx = min(1.2,  m.sx + 0.01); dirty_seed = reset_dots = true)
                U && (m.sy = min(1.2,  m.sy + 0.01); dirty_seed = reset_dots = true)
                D && (m.sy = max(-1.2, m.sy - 0.01); dirty_seed = reset_dots = true)

             elseif cmd
                L && (m.angle -= 0.03; dirty_seed = reset_dots = true)
                R && (m.angle += 0.03; dirty_seed = reset_dots = true)
                if U && m.sx > 0.001
                    factor = min(1.2, m.sx + 0.01) / m.sx
                    m.sx *= factor; m.sy *= factor; m.bx *= factor; m.by *= factor
                    dirty_seed = reset_dots = true
                end
                if D && m.sx > 0.01
                    factor = max(0.01, m.sx - 0.01) / m.sx
                    m.sx *= factor; m.sy *= factor; m.bx *= factor; m.by *= factor
                    dirty_seed = reset_dots = true
                end            else
                L && (m.tx -= 0.01; dirty_seed = reset_dots = true)
                R && (m.tx += 0.01; dirty_seed = reset_dots = true)
                U && (m.ty -= 0.01; dirty_seed = reset_dots = true)
                D && (m.ty += 0.01; dirty_seed = reset_dots = true)
            end
        end

        # --- TOP-LEFT: Seed Canvas ---
        ig.SetNextWindowPos(ig.ImVec2(10, 10), ig.ImGuiCond_Always)
        ig.Begin("Seed", C_NULL, flags | ig.ImGuiWindowFlags_AlwaysAutoResize)
        pos = ig.GetCursorScreenPos()
        ref1 = isdefined(ig, :ImTextureRef) ? ig.ImTextureRef(ig.ImTextureID(t1)) : ig.ImTextureID(t1)
        ig.Image(ref1, ig.ImVec2(Float32(W), Float32(W)))
        ig.SetCursorScreenPos(pos)
        ig.InvisibleButton("hit", ig.ImVec2(Float32(W), Float32(W)))
        if !locked[] && ig.IsItemActive() && ig.IsMouseDown(0)
            mp = ig.GetMousePos()
            px, py = round(Int, mp.x - pos.x) + 1, round(Int, mp.y - pos.y) + 1
            paint_line!(base_pxs, something(last_p[], (px, py)), px, py, Int(brush[]), true)
            last_p[] = (px, py); dirty_seed = true
        else
            last_p[] = nothing
        end
        ig.End()

        # --- GAP BETWEEN SEED CANVAS AND OUTPUT WINDOW ---
        gap_x = Float32(W + 30)
        gap_w = hw - gap_x - 8.0f0
        if gap_w > 90.0f0
            ig.SetNextWindowPos(ig.ImVec2(gap_x, 10), ig.ImGuiCond_Always)
            ig.SetNextWindowSize(ig.ImVec2(gap_w, Float32(W + 16)), ig.ImGuiCond_Always)
            ig.Begin("Legend", C_NULL, flags)

            ig.TextColored(ig.ImVec4(1.0f0, 1.0f0, 1.0f0, 1.0f0), "CONTROLS")
            ig.Separator()
            ig.Dummy(ig.ImVec2(0.0f0, 8.0f0))

            light_blue = ig.ImVec4(0.55f0, 0.80f0, 1.0f0, 1.0f0)
            white_col  = ig.ImVec4(1.0f0, 1.0f0, 1.0f0, 1.0f0)

            if !locked[]
                ig.PushStyleColor(ig.ImGuiCol_Text, light_blue)
                ig.TextWrapped("1. Draw your seed shape on the left canvas.")
                ig.Dummy(ig.ImVec2(0.0f0, 12.0f0))
                ig.TextWrapped("2. Press SPACE to lock seed & add Map 1.")
                ig.PopStyleColor()
                ig.Dummy(ig.ImVec2(0.0f0, 16.0f0))
                ig.TextWrapped("Brush width")
                ig.SetNextItemWidth(max(80.0f0, gap_w - 115.0f0))
                ig.SliderInt("", brush, 0, 8)
            else
                for (k, desc) in [
                    ("SPACE", "Add copy"),
                    ("TAB", "Next map (Shift+TAB previous)"),
                    ("Arrows", "Move selected map"),
                    ("Cmd + L / R", "Rotate map"),
                    ("Cmd + U / D", "Uniform scale"),
                    ("Option + Arrows", "X / Y stretch"),
                    ("Shift + Arrows", "X / Y shear"),
                    ("Shift+Opt+Arrows", "Quadratic bend"),
                    ("F / G", "Flip Horiz / Vert")
                ]
                    ig.TextColored(white_col, k)
                    ig.PushStyleColor(ig.ImGuiCol_Text, light_blue)
                    ig.TextWrapped(desc)
                    ig.PopStyleColor()
                    ig.Dummy(ig.ImVec2(0.0f0, 4.0f0))
                end
            end
            ig.End()
        end

        # --- BOTTOM-LEFT: Controls ---
        ty = Float32(W + 30)
        ig.SetNextWindowPos(ig.ImVec2(10, ty), ig.ImGuiCond_Always)
        ig.SetNextWindowSize(ig.ImVec2(hw - 18, max(160.0f0, fh - ty - 10)), ig.ImGuiCond_Always)
        ig.Begin("Tools", C_NULL, flags)

        ig.BeginChild("LeftCol", ig.ImVec2(345, 0), false)
        if ig.Button("Reset", ig.ImVec2(72, 0))
            fill!(base_pxs, false); empty!(pts); empty!(copies); locked[] = false; sel[] = 0
            out_sx[] = 1.0f0; out_sy[] = 1.0f0; out_ox[] = 0.0f0; out_oy[] = 0.0f0
            reset_acc!(acc); dirty_seed = recolor_only = true; status_msg[] = ""
        end
        ig.SameLine()
        if ig.Button("Remove", ig.ImVec2(80, 0)) && 1 <= sel[] <= length(copies)
            deleteat!(copies, sel[])
            sel[] = min(sel[], length(copies))
            dirty_seed = reset_dots = true
        end
        ig.SameLine()
        if ig.Button("Save IFS", ig.ImVec2(84, 0)) && !isempty(copies)
            save_kind[] = :ifs
            ig.OpenPopup("SaveNamePopup")
        end
        ig.SameLine()
        if ig.Button("Load IFS", ig.ImVec2(84, 0))
            preset_files[] = filter(f -> endswith(f, ".toml"), readdir("."))
            ig.OpenPopup("LoadPresetPopup")
        end

        if ig.Button("Save PNG", ig.ImVec2(98, 0)) && !isempty(copies)
            save_kind[] = :png
            ig.OpenPopup("SaveNamePopup")
        end
        if !isempty(status_msg[])
            ig.SameLine()
            ig.TextColored(ig.ImVec4(0.4f0, 0.95f0, 0.5f0, 1.0f0), status_msg[])
        end

        if ig.BeginPopup("SaveNamePopup")
            ext = save_kind[] == :ifs ? ".toml" : ".png"
            ig.Text("Enter name ($ext added automatically):")
            ig.SetNextItemWidth(240)
            ig.IsWindowAppearing() && ig.SetKeyboardFocusHere()
            enter_pressed = ig.InputText("##fname", name_buf, length(name_buf), ig.ImGuiInputTextFlags_EnterReturnsTrue)
            if ig.Button("Save", ig.ImVec2(115, 0)) || enter_pressed
                raw = read_str_buf(name_buf)
                if save_kind[] == :ifs
                    status_msg[] = "Saved: " * save_ifs_toml(raw, base_pxs, copies, prob_mode[], col_mode[], custom_rgb, seed_bg, out_bg, out_sx[], out_sy[], out_ox[], out_oy[], norm_on[], eq_on[])
                else
                    status_msg[] = "PNG: " * save_output_png(out_pxs, raw)
                end
                save_kind[] = :none
                ig.CloseCurrentPopup()
            end
            ig.SameLine()
            if ig.Button("Cancel", ig.ImVec2(115, 0))
                save_kind[] = :none
                ig.CloseCurrentPopup()
            end
            ig.EndPopup()
        else
            save_kind[] = :none
        end

        if ig.BeginPopup("LoadPresetPopup")
            if isempty(preset_files[])
                ig.Text("No .toml IFS files found in folder.")
            else
                for f in preset_files[]
                    if ig.Selectable(f)
                        load_ifs_toml!(f, base_pxs, pts, copies, prob_mode, col_mode, custom_rgb, seed_bg, out_bg, out_sx, out_sy, out_ox, out_oy, norm_on, eq_on)
                        locked[] = true
                        sel[] = isempty(copies) ? 0 : 1
                        dirty_seed = reset_dots = true
                        status_msg[] = "Loaded: " * f
                    end
                end
            end
            ig.EndPopup()
        end

        ig.Separator()

        for (i, m) in enumerate(copies)
            ig.PushID(i)
            if ig.ColorEdit3("##c", m.rgb, ig.ImGuiColorEditFlags_NoInputs)
                dirty_seed = true
                col_mode[] == 6 && (reset_dots = true)
            end
            ig.SameLine()
            mr, mg, mb = m.rgb
            c = ig.ImVec4(mr, mg, mb, 1.0f0)
            ig.PushStyleColor(ig.ImGuiCol_Button, c); ig.PushStyleColor(ig.ImGuiCol_ButtonHovered, c)
            if ig.Button(i == sel[] ? ">> Map $i <<" : "Map $i", ig.ImVec2(265, 22))
                sel[] = i; dirty_seed = true
            end
            ig.PopStyleColor(2)
            ig.PopID()
        end
        ig.EndChild()

        ig.SameLine()

        # Right Column
        ig.BeginChild("RightCol", ig.ImVec2(0, 0), false)
        ig.Text("Probabilities:"); ig.SameLine()
        ig.RadioButton("Equal", prob_mode, 1) && (reset_dots = true); ig.SameLine()
        ig.RadioButton("Weighted", prob_mode, 2) && (reset_dots = true)

        ig.Text("Colour:")
        ig.RadioButton("W/B", col_mode, 1) && (recolor_only = true); ig.SameLine()
        ig.RadioButton("Green", col_mode, 2) && (recolor_only = true); ig.SameLine()
        ig.RadioButton("Red", col_mode, 3) && (recolor_only = true); ig.SameLine()
        ig.RadioButton("Blue", col_mode, 4) && (recolor_only = true)
        ig.RadioButton("Map", col_mode, 6) && (recolor_only = true); ig.SameLine()
        ig.RadioButton("Custom", col_mode, 5) && (recolor_only = true)
        if col_mode[] == 5
            ig.SameLine()
            ig.ColorEdit3("##cust", custom_rgb, ig.ImGuiColorEditFlags_NoInputs) && (recolor_only = true)
        end

        ig.PushItemWidth(135)
        ig.SliderFloat("Out X-Scale", out_sx, 0.2f0, 2.5f0) && (reset_dots = true)
        ig.SameLine()
        ig.SliderFloat("Out Y-Scale", out_sy, 0.2f0, 2.5f0) && (reset_dots = true)

        ig.SliderFloat("Out X-Offset", out_ox, -0.5f0, 0.5f0) && (reset_dots = true)
        ig.SameLine()
        ig.SliderFloat("Out Y-Offset", out_oy, -0.5f0, 0.5f0) && (reset_dots = true)
        ig.PopItemWidth()

        ig.Text("Intensity:"); ig.SameLine()
        ig.Checkbox("Normalize", norm_on) && (recolor_only = true); ig.SameLine()
        ig.Checkbox("Equalize", eq_on) && (recolor_only = true)

        ig.ColorEdit3("Seed BG", seed_bg, ig.ImGuiColorEditFlags_NoInputs) && (dirty_seed = true); ig.SameLine()
        ig.ColorEdit3("Out BG", out_bg, ig.ImGuiColorEditFlags_NoInputs) && (recolor_only = true)

        ig.PushItemWidth(220)
        if ig.SliderInt("Max Idle Dots", max_dots, 250_000, 5_000_000)
            acc.total_dots > max_dots[] && (reset_dots = true)
        end
        ig.PopItemWidth()
        ig.SameLine()
        ig.Text("($(acc.total_dots ÷ 1000)k)")
        ig.EndChild()
        ig.End()

        dirty_seed && render_seed!(disp_pxs, base_pxs, pts, copies, sel[], seed_bg, t1)

        if reset_dots
            reset_acc!(acc)
            accumulate_dots!(acc, copies, prob_mode[], out_sx[], out_sy[], out_ox[], out_oy[], min(250_000, Int(max_dots[])))
            tone_map_output!(out_pxs, acc, copies, col_mode[], custom_rgb, out_bg, norm_on[], eq_on[], t2)
        elseif !isempty(copies) && acc.total_dots < max_dots[]
            step = min(150_000, Int(max_dots[]) - acc.total_dots)
            accumulate_dots!(acc, copies, prob_mode[], out_sx[], out_sy[], out_ox[], out_oy[], step)
            tone_map_output!(out_pxs, acc, copies, col_mode[], custom_rgb, out_bg, norm_on[], eq_on[], t2)
        elseif recolor_only
            tone_map_output!(out_pxs, acc, copies, col_mode[], custom_rgb, out_bg, norm_on[], eq_on[], t2)
        end

        # --- RIGHT HALF: IFS Output (Full-Bleed Edge-to-Edge) ---
        ig.SetNextWindowPos(ig.ImVec2(hw, 10), ig.ImGuiCond_Always)
        ig.SetNextWindowSize(ig.ImVec2(hw - 10, fh - 20), ig.ImGuiCond_Always)
        ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, ig.ImVec2(0.0f0, 0.0f0))
        ig.Begin("Output", C_NULL, flags | ig.ImGuiWindowFlags_NoScrollbar)
        av = ig.GetContentRegionAvail()
        ref2 = isdefined(ig, :ImTextureRef) ? ig.ImTextureRef(ig.ImTextureID(t2)) : ig.ImTextureID(t2)
        ig.Image(ref2, ig.ImVec2(av.x, av.y))
        ig.End()
        ig.PopStyleVar()
    end
end

function make_tex(img)
    t = Ref(GL.GLuint(0)); GL.glGenTextures(1, t); GL.glBindTexture(GL.GL_TEXTURE_2D, t[])
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, GL.GL_LINEAR)
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, GL.GL_NEAREST)
    GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, size(img,1), size(img,2), 0, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, img)
    return t[]
end

function upload_tex!(t, img)
    GL.glBindTexture(GL.GL_TEXTURE_2D, t)
    GL.glTexSubImage2D(GL.GL_TEXTURE_2D, 0, 0, 0, size(img,1), size(img,2), GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, img)
end

main()
