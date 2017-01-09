gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

node.alias "*" -- catch all communication

util.noglobals()

local json = require "json"
local easing = require "easing"
local loader = require "loader"

local min, max, abs, floor = math.min, math.max, math.abs, math.floor

local IDLE_ASSET = "empty.png"

local overlay_debug = false

local overlays = {
    resource.create_colored_texture(1,0,0),
    resource.create_colored_texture(0,1,0),
    resource.create_colored_texture(0,0,1),
    resource.create_colored_texture(1,0,1),
    resource.create_colored_texture(1,1,0),
    resource.create_colored_texture(0,1,1),
}

local function in_epsilon(a, b, e)
    return abs(a - b) <= e
end

local function ramp(t_s, t_e, t_c, ramp_time)
    if ramp_time == 0 then return 1 end
    local delta_s = t_c - t_s
    local delta_e = t_e - t_c
    return min(1, delta_s * 1/ramp_time, delta_e * 1/ramp_time)
end

local function wait_frame()
    return coroutine.yield(true)
end

local function wait_t(t)
    while true do
        local now = wait_frame()
        if now >= t then
            return now
        end
    end
end

local function from_to(starts, ends)
    return function()
        local now, x1, y1, x2, y2
        while true do
            now, x1, y1, x2, y2 = wait_frame()
            if now >= starts then
                break
            end
        end
        if now < ends then
            return now, x1, y1, x2, y2
        end
    end
end


local function mktween(fn)
    return function(sx1, sy1, sx2, sy2, ex1, ey1, ex2, ey2, progress)
        return fn(progress, sx1, ex1-sx1, 1),
               fn(progress, sy1, ey1-sy1, 1),
               fn(progress, sx2, ex2-sx2, 1),
               fn(progress, sy2, ey2-sy2, 1)
    end
end

local movements = {
    linear = mktween(easing.linear),
    smooth = mktween(easing.inOutQuint),
}

local function Clock()
    local base_time = 0
    local base_day = 0
    local day = 0

    util.data_mapper{
        ["clock/midnight"] = function(since_midnight)
            base_day = tonumber(since_midnight) - sys.now()
        end;
        ["clock/set"] = function(time)
            base_time = tonumber(time) - sys.now()
        end;
        ["clock/day"] = function(new_day)
            day = new_day
        end;
    }

    local function get_human()
        local time = (base_day + sys.now()) % 86400
        return string.format("%02d:%02d", math.floor(time / 3600), math.floor(time % 3600 / 60))
    end

    local function get_unix()
        return base_time + sys.now()
    end

    local function get_day()
        return day
    end

    return {
        get_human = get_human;
        get_unix = get_unix;
        get_day = get_day;
    }
end

local clock = Clock()

local SharedData = function()
    -- {
    --    scope: { key: data }
    -- }
    local data = {}

    -- {
    --    key: { scope: listener }
    -- }
    local listeners = {}

    local function call_listener(scope, listener, key, value)
        local ok, err = xpcall(listener, debug.traceback, scope, value)
        if not ok then
            print("while calling listener for key " .. key .. ":" .. err)
        end
    end

    local function call_listeners(scope, key, value)
        local key_listeners = listeners[key]
        if not key_listeners then
            return
        end

        for _, listener in pairs(key_listeners) do
            call_listener(scope, listener, key, value)
        end
    end

    local function update(scope, key, value)
        if not data[scope] then
            data[scope] = {}
        end
        data[scope][key] = value
        if value == nil and not next(data[scope]) then
            data[scope] = nil
        end
        return call_listeners(scope, key, value)
    end

    local function delete(scope, key)
        return update(scope, key, nil)
    end

    local function add_listener(scope, key, listener)
        local key_listeners = listeners[key]
        if not key_listeners then
            listeners[key] = {}
            key_listeners = listeners[key]
        end
        if key_listeners[scope] then
            error "right now only a single listener is supported per scope"
        end
        key_listeners[scope] = listener
        for scope, scoped_data in pairs(data) do
            for key, value in pairs(scoped_data) do
                call_listener(scope, listener, key, value)
            end
        end
    end

    local function del_scope(scope)
        for key, key_listeners in pairs(listeners) do
            key_listeners[scope] = nil
            if not next(key_listeners) then
                listeners[key] = nil
            end
        end

        local scoped_data = data[scope]
        if scoped_data then
            for key, value in pairs(scoped_data) do
                delete(scope, key)
            end
        end
        data[scope] = nil
    end

    return {
        update = update;
        delete = delete;
        add_listener = add_listener;
        del_scope = del_scope;
    }
end

local data = SharedData()

local tiles = loader.setup "tile.lua"
tiles.make_api = function(tile)
    return {
        wait_frame = wait_frame,
        wait_t = wait_t,
        from_to = from_to,

        clock = clock,

        update_data = function(key, value)
            data.update(tile, key, value)
        end,
        delete_data = function(key)
            data.delete(tile, key)
        end,
        add_listener = function(key, listener)
            data.add_listener(tile, key, listener)
        end,
    }
end

node.event("module_unload", function(tile)
    data.del_scope(tile)
end)

local function TileChild(entry)
    local function task(starts, ends)
        local tile = tiles.modules[entry.item.asset_name]
        -- print("TILE=", tile)
        local custom = entry.custom
        return tile.task(starts, ends, custom)
    end

    local function destroy()
    end

    return {
        task = task;
        destroy = destroy;
    }
end

local kenburns_shader = resource.create_shader[[
    uniform sampler2D Texture;
    varying vec2 TexCoord;
    uniform vec4 Color;
    uniform float x, y, s;
    void main() {
        gl_FragColor = texture2D(Texture, TexCoord * vec2(s, s) + vec2(x, y)) * Color;
    }
]]

local function Image(entry)
    -- custom:
    --   kenburns: true/false
    --   fade_time: 0-1
    --   fit: true/false

    local asset = resource.open_file(entry.item.asset_name)

    local function task(starts, ends)
        local file = asset:copy()

        wait_t(starts - 2)

        local img = resource.load_image(file)

        local custom = entry.custom
        local fade_time = custom.fade_time or 0.5
        local fit = custom.fit

        if custom.kenburns then
            local function lerp(s, e, t)
                return s + t * (e-s)
            end

            local paths = {
                {from = {x=0.0,  y=0.0,  s=1.0 }, to = {x=0.08, y=0.08, s=0.9 }},
                {from = {x=0.05, y=0.0,  s=0.93}, to = {x=0.03, y=0.03, s=0.97}},
                {from = {x=0.02, y=0.05, s=0.91}, to = {x=0.01, y=0.05, s=0.95}},
                {from = {x=0.07, y=0.05, s=0.91}, to = {x=0.04, y=0.03, s=0.95}},
            }

            local path = paths[math.random(1, #paths)]

            local to, from = path.to, path.from
            if math.random() >= 0.5 then
                to, from = from, to
            end

            local w, h = img:size()
            local duration = ends - starts
            local linear = easing.linear

            local function lerp(s, e, t)
                return s + t * (e-s)
            end

            for now, x1, y1, x2, y2 in from_to(starts, ends) do
                local t = (now - starts) / duration
                kenburns_shader:use{
                    x = lerp(from.x, to.x, t);
                    y = lerp(from.y, to.y, t);
                    s = lerp(from.s, to.s, t);
                }
                if fit then
                    util.draw_correct(img, x1, y1, x2, y2, ramp(
                        starts, ends, now, fade_time
                    ))
                else
                    img:draw(x1, y1, x2, y2, ramp(
                        starts, ends, now, fade_time
                    ))
                end
                kenburns_shader:deactivate()
            end
        else
            for now, x1, y1, x2, y2 in from_to(starts, ends) do
                if fit then
                    util.draw_correct(img, x1, y1, x2, y2, ramp(
                        starts, ends, now, fade_time
                    ))
                else
                    img:draw(x1, y1, x2, y2, ramp(
                        starts, ends, now, fade_time
                    ))
                end
            end
        end
        img:dispose()
    end

    local function destroy()
        asset:dispose()
    end

    return {
        task = task;
        destroy = destroy;
    }
end

local function Idle(entry)
    return {
        task = function() end;
        destroy = function() end;
    }
end

local function Video(entry)
    -- custom:
    --   fit: aspect fit or scale?
    --   fade_time: 0-1
    --   raw: use raw video?
    --   layer: video layer for raw videos

    local asset = resource.open_file(entry.item.asset_name)

    local function task(starts, ends)
        local file = asset:copy()

        wait_t(starts - 2)

        local custom = entry.custom
        local fade_time = custom.fade_time or 0.5
        local fit = custom.fit
        local raw = custom.raw

        local vid
        if raw then
            local raw = sys.get_ext "raw_video"
            vid = raw.load_video{
                file = file,
                paused = true,
            }

            for now, x1, y1, x2, y2 in from_to(starts, ends) do
                vid:target(x1, y1, x2, y2):alpha(ramp(
                    starts, ends, now, fade_time
                )):layer(custom.layer or -5):start()
            end
        else
            vid = resource.load_video{
                file = file,
                paused = true,
            }

            for now, x1, y1, x2, y2 in from_to(starts, ends) do
                vid:start()
                if fit then
                    util.draw_correct(vid, x1, y1, x2, y2, ramp(
                        starts, ends, now, fade_time
                    ))
                else
                    vid:draw(x1, y1, x2, y2, ramp(
                        starts, ends, now, fade_time
                    ))
                end
            end
        end

        vid:dispose()
    end

    local function destroy()
        asset:dispose()
    end

    return {
        task = task;
        destroy = destroy;
    }
end

local function Track(new_config)
    local fallback_playlist = {{
        item = {
            asset_name = IDLE_ASSET,
            type = "image";
        },
        duration = 1;
        x1 = 0,
        y1 = 0,
        x2 = WIDTH,
        y2 = HEIGHT,
    }}

    local x1, y1, x2, y2 -- current location
    local dx1, dy1, dx2, dy2 -- destination
    local sx1, sy1, sx2, sy2 -- source
    local transition_starts, transition_ends

    local scheduled_until = -1
    local jobs = {}

    local playlist = {}
    local total_duration = 0

    local function enqueue(item, starts, ends)
        -- print("enqueing ", starts, ends)
        local job = {
            co = coroutine.create(item.player.task),
            coord = {
                x1 = item.entry.x1,
                y1 = item.entry.y1,
                x2 = item.entry.x2,
                y2 = item.entry.y2,
            },
            transition_starts = ends - item.entry.transition,
            transition_ends = starts + item.entry.transition,
        }
        local ok, again = coroutine.resume(job.co, starts, ends)
        if not ok then
            return error(("%s\n%s\ninside coroutine %s started by"):format(
                again, debug.traceback(job.co), job)
            )
        elseif again then
            jobs[#jobs+1] = job
        end
    end

    local function schedule_next_job()
        local unix, now = os.time(), sys.now()
        if now < 2 then -- or unix < 1000000
            -- Just started (or valid wall clock time)?
            -- Don't schedule anything yet. When info-beamer
            -- starts, the first few frames have odd timings
            -- as the gl surfaces does some internal stuff.
            -- So we just wait until info-beamer ran for
            -- 2 seconds. Everything is settled down then.
            return
        end
        local diff = now - unix

        local tolerance = 0.25

        local cycle = floor(unix / total_duration)
        for cycle_offset = 0, 1 do
            local base = (cycle + cycle_offset) * total_duration
            for idx = 1, #playlist do
                local slot = playlist[idx]
                local starts = diff + base + slot.offset

                if starts >= scheduled_until - tolerance then
                    local ends = starts + slot.duration
                    if in_epsilon(starts, scheduled_until, tolerance) then
                        -- print("SNAPPING", starts - scheduled_until)
                        starts = scheduled_until
                    else
                        print("NOT SNAPPING", starts - scheduled_until)
                    end
                    scheduled_until = ends
                    local num_items = #slot.items
                    local item = slot.items[math.random(
                        1, num_items
                    )]
                    return enqueue(item, starts, ends)
                end
            end
        end
    end

    local function update_playlist(new_playlist)
        print "setting playlist"
        for idx = 1, #playlist do
            local slot = playlist[idx]
            for idx = 1, #slot.items do
                local item = slot.items[idx]
                item.player.destroy()
            end
        end

        playlist = {}

        if #new_playlist == 0 then
            -- no items? use fallback
            new_playlist = fallback_playlist
        end

        local offset = 0
        local items = {}

        for idx = 1, #new_playlist do
            local entry = new_playlist[idx]
            items[#items+1] = {
                player = ({
                    image = (function()
                        if entry.item.asset_name == IDLE_ASSET then
                            return Idle
                        else
                            return Image
                        end
                    end)(),
                    video = Video,
                    child = TileChild,
                })[entry.item.type](entry),
                entry = entry,
            }

            if entry.duration > 0 then
                playlist[#playlist+1] = {
                    items = items,
                    duration = entry.duration,
                    offset = offset,
                }
                items = {}
            end
            offset = offset + entry.duration
        end
        total_duration = offset

        -- set initial coordinates
        if not x1 then
            x1 = playlist[1].items[1].entry.x1
            y1 = playlist[1].items[1].entry.y1
            x2 = playlist[1].items[1].entry.x2
            y2 = playlist[1].items[1].entry.y2
        end
    end

    local function update(new_config)
        update_playlist(new_config.playlist)
    end

    update(new_config)

    local function tick()
        if #jobs <= 1 then
            schedule_next_job()
        end

        local now = sys.now()

        for idx = #jobs,1,-1 do -- iterate backwards so we can remove finished jobs
            local job = jobs[idx]
            local next_job = jobs[idx+1]

            if not transition_starts then 
                -- not in a transition
                if now >= job.transition_starts and next_job then
                    sx1, sy1, sx2, sy2 = x1, y1, x2, y2
                    dx1, dy1, dx2, dy2 = 
                        next_job.coord.x1, next_job.coord.y1, next_job.coord.x2, next_job.coord.y2
                    transition_starts = now
                    transition_ends = next_job.transition_ends
                end
            else
                -- in a transition
                if now <= transition_ends then
                    local duration = transition_ends - transition_starts
                    local progress = 1.0 / duration * (now - transition_starts)
                    x1, y1, x2, y2 = movements['smooth'](
                        sx1, sy1, sx2, sy2,
                        dx1, dy1, dx2, dy2,
                        progress
                    )
                else
                    x1, y1, x2, y2 = dx1, dy1, dx2, dy2
                    transition_starts = nil
                    transition_ends = nil
                end
            end

            if overlay_debug then
                overlays[(idx-1)%#overlays+1]:draw(x1, y1, x2, y2, 0.1)
            end

            local ok, again = coroutine.resume(job.co, now, x1, y1, x2, y2)
            if not ok then
                print(("%s\n%s\ninside coroutine %s resumed by"):format(
                    again, debug.traceback(job.co), job)
                )
                table.remove(jobs, idx)
            elseif not again then
                table.remove(jobs, idx)
            end
        end
        -- pp(jobs)
    end

    local function destroy()
        jobs = {}
        node.gc()
    end

    return {
        update = update;
        tick = tick;
        destroy = destroy;
    }
end

local function Tracks()
    local tracks = {}

    local function update(new_tracks)
        for idx = 1, #new_tracks do
            local config = new_tracks[idx]
            if tracks[idx] then
                tracks[idx].update(config)
            else
                tracks[idx] = Track(config)
            end
        end
        for idx = #tracks, #new_tracks+1, -1 do
            local track = tracks[idx]
            track.destroy()
            tracks[idx] = nil
        end
    end

    local function tick()
        for idx = 1, #tracks do
            local track = tracks[idx]
            track.tick()
        end
    end

    return {
        update = update;
        tick = tick;
    }
end

local Tracks = Tracks()

util.file_watch("config.json", function(raw)
    local config = json.decode(raw)
    Tracks.update(config.tracks)
end)

function node.render()
    local fov = math.atan2(HEIGHT, WIDTH*2) * 360 / math.pi
    gl.perspective(fov, WIDTH/2, HEIGHT/2, -WIDTH,
                        WIDTH/2, HEIGHT/2, 0)
    Tracks.tick()
end
