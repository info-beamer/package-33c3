local api, CHILDS, CONTENTS = ...

local json = require "json"
local utils = require(api.localized "utils")
local anims = require(api.localized "anims")

local M = {}

local font, room_font, info_bar_font
local white = resource.create_colored_texture(1,1,1)
local full_overlay = resource.create_colored_texture(1,0,0,0.3)
local full_overlay_2 = resource.create_colored_texture(0,0,0,0.8)
local header_color
local content_color
local content_color_tex
local background
local headers = {}
local margin

local schedule = {}
local rooms = {}
local next_talks = {}
local current_room
local current_talk
local this_talk
local last_talk
local other_talks = {}
local last_check_min = 0
local day = 0
local full = {}

local M = {}

util.data_mapper{
    [api.localized "day"] = function(new_day)
        day = new_day
    end;
}

local function rgba(color, alpha)
    return color.r, color.g, color.b, alpha or color.a
end

local function load_unless_empty(asset)
    if asset.asset_name == "empty.png" then
        return nil
    else
        return resource.load_image(api.localized(asset.asset_name))
    end
end


function M.updated_schedule_json(new_schedule)
    print "new schedule"
    schedule = new_schedule
end

function M.updated_saalvoll_json(new_full)
    print "new full"
    full = new_full
end

function M.updated_config_json(config)
    rooms = {}
    for idx = 1, #config.rooms do
        local room = config.rooms[idx]
        if room.serial == sys.get_env("SERIAL") then
            print("found my room")
            current_room = room
        end
        rooms[room.name] = room
    end

    if current_room then
        local info_lines = {}
        for line in string.gmatch(current_room.info.."\n", "([^\n]*)\n") do
            local split = string.find(line, ",")
            if not split then
                info_lines[#info_lines+1] = "splitter"
            else
                info_lines[#info_lines+1] = {
                    name = string.sub(line, 1, split-1),
                    value = string.sub(line, split+1),
                }
            end
        end
        current_room.info_lines = info_lines
    end
  
    background = load_unless_empty(config.background)
    headers = {
        next_talk = load_unless_empty(config.next_talk),
        this_talk = load_unless_empty(config.this_talk),
        other_talks = load_unless_empty(config.other_talks),
        room_info = load_unless_empty(config.room_info),
    }

    header_color = config.header_color
    content_color = config.content_color
    content_color_tex = resource.create_colored_texture(rgba(content_color))
    margin = config.margin
    font = resource.load_font(api.localized(config.font.asset_name))
    room_font = resource.load_font(api.localized(config.room_font.asset_name))
    info_bar_font = resource.load_font(api.localized(config.info_bar_font.asset_name))
end

local function draw_with_progress(a, starts, ends)
    for now, x1, y1, x2, y2 in api.from_to(starts, ends) do
        a.draw(now, x1, y1, x2, y2)
        local progress = (now-starts)/(ends-starts)
        white:draw(x1, y2-10, x1+(x2-x1)*progress, y2, 0.5)
    end
end

local function text_or_image(S, E, text, r, g, b, a)
    local img = headers[text:gsub(" ", "_")]
    local y = 150
    if img then
        local w, h = img:size()
        return anims.moving_image_raw(S,E, img, 
            10, y, 10+w, y+h
        )
    else
        return anims.moving_font(S, E, font, 10, y, text, 80, r, g, b, a)
    end
end

local function check_next_talk()
    local now = api.clock.get_unix()
    local check_min = math.floor(now / 60)
    if check_min == last_check_min then
        return
    end
    last_check_min = check_min

    local function format_talk(talk)
        talk.next_talk_lines = utils.wrap(talk.title, 30)
        talk.other_talks_lines = utils.wrap(talk.title, 50)
        talk.abstract_lines = utils.wrap(talk.abstract, 60)
        if rooms[talk.place] then
            talk.place_short = rooms[talk.place].name_short
        else
            talk.place_short = talk.place
        end
        if not talk.speakers or #talk.speakers == 0 then
            talk.speaker_line = "unknown speaker"
        else
            talk.speaker_line = table.concat(talk.speakers, ", ")
        end
        return talk
    end

    local room_next = {}
    local room_last = {}

    print("num talks: " .. #schedule)
    local lineup = {}
    local running = {}
    for idx = 1, #schedule do
        local talk = schedule[idx]

        -- In Räume gruppieren
        if (current_room.group == "*" or current_room.group == talk.group) and
            rooms[talk.place]
        then
            if not room_next[talk.place] and 
                talk.start_unix > now - 25 * 60 then
                room_next[talk.place] = format_talk(talk)
            end
            if not room_last[talk.place] and 
                now > talk.start_unix + 15 * 60 and
                now < talk.end_unix + 10 * 60 then
                room_last[talk.place] = format_talk(talk)
            end
        end

        -- Aktuell laufende
        if now > talk.start_unix and now < talk.end_unix then
           running[talk.place] = format_talk(talk)

           -- Was passiert als nächstes?
           if talk.start_unix + 15 * 60 > now then
               lineup[#lineup+1] = format_talk(talk)
           end
        end

        -- Bald startende
        if talk.start_unix > now and #lineup < 20 then
            lineup[#lineup+1] = format_talk(talk)
        end
    end

    current_talk = room_next[current_room.name]
    last_talk = room_last[current_room.name]
    this_talk = running[current_room.name]

    local function sort_talks(a, b)
        return a.start_unix < b.start_unix or (a.start_unix == b.start_unix and a.place < b.place)
    end

    -- Prepare talks for other rooms
    other_talks = {}
    for room, talk in pairs(room_next) do
        if not current_talk or room ~= current_talk.place then
            other_talks[#other_talks + 1] = talk
        end
    end
    table.sort(other_talks, sort_talks)
    print("found " .. #other_talks .. " other talks")


    -- Prepare next talks
    table.sort(lineup, sort_talks)
    next_talks = {}
    local scroller = {}
    local places = {}
    local redundant = false
    for idx = 1, math.min(20, #lineup) do
        local talk = lineup[idx]
        redundant = redundant or places[talk.place];
        next_talks[#next_talks+1] = {
            speakers = #talk.speakers == 0 and {"?"} or talk.speakers;
            place = talk.place;
            place_short = talk.place_short;
            lines = utils.wrap(talk.title .. " (" .. talk.lang .. ")", 30);
            start_str = talk.start_str;
            start_unix = talk.start_unix;
            redundant = redundant;
            started = talk.start_unix < now;
        }
        scroller[#scroller+1] = {
            text = "@" .. talk.start_str .. ": " .. talk.title .. " at " .. talk.place_short
        }
        if talk.start_unix > now then
            places[talk.place] = true
        end
    end

    api.update_data("scroller", scroller)
end

local function view_next_talk(starts, ends)
    local a = anims.Area(1280, 720)

    local S = starts
    local E = ends

    local function text(...)
        return a.add(anims.moving_font(S, E, font, ...))
    end

    if #schedule == 0 then
        text(300, 350, "Loading...", 80, rgba(header_color))
    elseif not current_talk then
        text(300, 350, "Nope. That's it.", 80, rgba(header_color))
    else
        local delta = current_talk.start_unix - api.clock.get_unix()
        if delta > 0 then
            a.add(text_or_image(S, E, "next talk", rgba(header_color)))
        else
            a.add(text_or_image(S, E, "this talk", rgba(header_color)))
        end

        text(10, 350, current_talk.start_str, 50, rgba(content_color))
        if delta > 180*60 then
            text(10, 350 + 60, string.format("in %d h", math.floor(delta/3600)), 50,
                rgba(content_color)
            )
        elseif delta > 0 then
            text(10, 350 + 60, string.format("in %d min", math.floor(delta/60)+1), 50,
                rgba(content_color)
            )
        end
        for idx = 1, math.min(5, #current_talk.next_talk_lines) do
            local line = current_talk.next_talk_lines[idx]
            text(430, 350 + 50 * (idx-1), line, 50,
                rgba(content_color)
            )
        end

        local y = 570
        for idx = 1, #current_talk.speakers do
            local speaker = current_talk.speakers[idx]
            y = 570 + 30 * math.floor((idx-1)/2)
            text(430 + ((idx-1)%2) * 350, y, speaker, 30,
                rgba(content_color, 0.8)
            )
        end

        if background then
            a.add(anims.moving_image_raw(S,E, background,
                0, 350-margin, 1270, y+30+margin
            ), 1)
        end
    end

    return draw_with_progress(a, starts, ends)
end

local function view_talk_info(starts, ends)
    local a = anims.Area(1280, 720)

    local S = starts
    local E = ends

    local function text(...)
        return a.add(anims.moving_font(S, E, font, ...))
    end

    a.add(text_or_image(S, E, "this talk", rgba(header_color)))
    if not this_talk then
        text(250, 400, "NO CURRENT SHOW", 80, rgba(header_color))
    else
        local y = 350
        for idx = 1, #this_talk.abstract_lines do
            local line = this_talk.abstract_lines[idx]
            text(10, y, line, 40, rgba(content_color))
            y = y + 40
        end
        if this_talk.link ~= "" then
            y = y + 5
            text(10, y, this_talk.link, 30, rgba(content_color, 0.8))
            y = y + 30
        end

        if background then
            a.add(anims.moving_image_raw(S,E, background,
                0, 350-margin, 1270, y+30+margin
            ), 1)
        end
    end

    return draw_with_progress(a, starts, ends)
end

local function view_other_talks(starts, ends)
    local a = anims.Area(1280, 720)

    local S = starts
    local E = ends

    local function text(...)
        return a.add(anims.moving_font(S, E, font, ...))
    end

    local y = 350

    local function mk_spacer()
        a.add(anims.moving_image_raw(S,E, content_color_tex,
            0, y-2, 1280, y+2, 0.3
        ))
        y = y + 10
    end

    local function mk_talk(talk, is_running)
        local alpha
        if is_running then
            alpha = 0.5
        else
            alpha = 1.0
        end

        text(10, y, talk.start_str, 50, rgba(content_color))

        a.add(anims.moving_font(S, E, room_font, 170, y,
            talk.place_short, 50, rgba(content_color)
        ))
        for idx = 1, #talk.other_talks_lines do
            local title = talk.other_talks_lines[idx]
            text(460, y, title, 30, rgba(content_color))
            y = y + 32
        end
        text(460, y, talk.speaker_line, 26, rgba(content_color, 0.8))
        y = y + 32
    end

    a.add(text_or_image(S, E, "other talks", rgba(header_color)))

    local time_sep = false
    if #other_talks > 0 then
        for idx = 1, #other_talks do
            local talk = other_talks[idx]
            if not time_sep and talk.start_unix > api.clock.get_unix() then
                if idx > 1 then
                    mk_spacer()
                end
                time_sep = true
            end
            mk_talk(talk, not time_sep)
            if y > 720 - 80 then
                break
            end
        end
    else
        text(300, 350, "No other talks.", 80, rgba(content_color))
        y = y + 80
    end

    if background then
        a.add(anims.moving_image_raw(S,E, background,
            0, 350-margin, 1270, y+margin
        ), 1)
    end

    draw_with_progress(a, starts, ends)
end

local function view_room_info(starts, ends)
    local a = anims.Area(1280, 720)

    local S = starts
    local E = ends

    local function text(...)
        return a.add(anims.moving_font(S, E, font, ...))
    end

    a.add(text_or_image(S, E, "room info", rgba(header_color)))

    local y = 350

    local info_lines = current_room.info_lines
    for idx = 1, #info_lines do 
        local line = info_lines[idx]
        if line == "splitter" then
            y = y + 25
        else
            text(10, y, line.name, 50, rgba(content_color))
            text(360, y, line.value, 50, rgba(content_color))
            y = y + 50
        end
    end

    if background then
        a.add(anims.moving_image_raw(S,E, background,
            0, 350-margin, 1270, y+margin
        ), 1)
    end

    draw_with_progress(a, starts, ends)
end

local function view_all_talks(starts, ends, custom)
    local a = anims.Area(1920, custom.height or 1080)

    local S = starts
    local E = ends

    local SPEAKER_SIZE = 50
    local TITLE_SIZE = 60
    local TIME_SIZE = 60

    local SPLIT_X = 240

    local function text(font, ...)
        return a.add(anims.moving_font(S, E, font, ...))
    end

    local y = 20
    local x = 100

    if #next_talks == 0 and #schedule > 0 and sys.now() > 30 then
        text(font, x+180, (a.height-160)/2, "No more talks :(", 160, 1,1,1,1); y=y+60; S=S+0.5
    end

    local full_shown = {}
    local now = api.clock.get_unix()

    for idx = 1, #next_talks do
        local talk = next_talks[idx]

        if y + #talk.lines * TITLE_SIZE + SPEAKER_SIZE > a.height then
            break
        end

        local start_y = y

        local time
        local show_full = false
        local til = talk.start_unix - now
        if til > -60 and til < 60 then
            time = "Now"
            local w = font:width(time, TIME_SIZE)
            -- 009a93
            text(font, x+SPLIT_X-20-w, y, time, TIME_SIZE, 0,.6,0.57,1)
            show_full = true
        elseif til > 0 and til < 15 * 60 then
            time = string.format("In %d min", math.floor(til/60))
            local w = font:width(time, TIME_SIZE)
            text(font, x+SPLIT_X-20-w, y, time, TIME_SIZE, 0,.6,0.57,1)
            show_full = true
        elseif talk.start_unix > now then
            time = talk.start_str
            local w = font:width(time, TIME_SIZE)
            text(font, x+SPLIT_X-20-w, y, time, TIME_SIZE, 1,1,1,1)
        else
            time = string.format("%d min ago", math.ceil(-til/60))
            local w = font:width(time, TIME_SIZE)
            text(font, x+SPLIT_X-20-w, y, time, TIME_SIZE, .5,.5,.5,1)
            show_full = true
        end

        for idx = 1, #talk.lines do
            local line = talk.lines[idx]
            text(font, x+SPLIT_X+20, y, line, TITLE_SIZE, 1,1,1,1)
            y = y + TITLE_SIZE
        end

        y = y + 5

        local line_x = x+SPLIT_X+20

        local location = talk.place_short
        text(room_font, line_x, y, location, SPEAKER_SIZE, .5,.5,.5,1)
        line_x = line_x + room_font:width(location, SPEAKER_SIZE)

        local with = ", "
        text(font, line_x, y, with, SPEAKER_SIZE, .5,.5,.5,1)
        line_x = line_x + font:width(with, SPEAKER_SIZE)

        local random_speaker = talk.speakers[math.random(1, #talk.speakers)]
        text(font, line_x, y, random_speaker, SPEAKER_SIZE, .5,.5,.5,1)
        line_x = line_x + font:width(random_speaker, SPEAKER_SIZE) + 5
        if #talk.speakers > 1 then
            local plus = " (+" .. (#talk.speakers-1) .. ")"
            text(font, line_x, y, plus, SPEAKER_SIZE, .5,.5,.5,1)
            line_x = line_x + font:width(plus, SPEAKER_SIZE)
        end

        y = y + SPEAKER_SIZE

        if show_full and full[talk.place] and not full_shown[talk.place] then
            full_shown[talk.place] = true
            local FULL_SIZE = 80
            local y_center = start_y + (y - start_y)/2 - FULL_SIZE/2
            local overlay_x = math.max(line_x + 10, 1270)
            a.add(anims.moving_image_raw(S,E, full_overlay,
                10, start_y, overlay_x, y
            ))
            a.add(anims.moving_image_raw(S+4,E, full_overlay_2,
                10, start_y, overlay_x, y
            ))
            a.add(anims.moving_font(S+4, E, font, x + SPLIT_X + 80, y_center, 
                "FULL: NO ENTRY", FULL_SIZE, 1,0,0,1
            ))
        end

        -- for j = 1, #talk.speakers do
        --     local speaker = talk.speakers[j]

        --     text(font, line_x, y, speaker, SPEAKER_SIZE, .5,.5,.5,1)
        --     line_x = line_x + font:width(speaker, SPEAKER_SIZE) + 5

        --     if j < #talk.speakers then
        --         text(font, line_x, y, ",", SPEAKER_SIZE, .5,.5,.5,1)
        --         line_x = line_x + 20
        --     end
        -- end

        y = y + 25
    end

    for now, x1, y1, x2, y2 in api.from_to(starts, ends) do
        a.draw(now, x1, y1, x2, y2)
    end
end

local function view_info_bar(starts, ends)
    for now, x1, y1, x2, y2 in api.from_to(starts, ends) do
        local line = current_room.name_short.. "    DAY " .. day .. "    " .. api.clock.get_human()
        info_bar_font:write(x1, y1, line, y2 - y1, 1,1,1,1)
    end
end

local function view_clock(starts, ends)
    for now, x1, y1, x2, y2 in api.from_to(starts, ends) do
        local line = "DAY " .. day .. "    " .. api.clock.get_human()
        if background then
            local margin = 10 -- XXX: configurable?
            background:draw(x1, y1-margin, x2, y2+margin)
        end
        info_bar_font:write(x1, y1, line, y2 - y1, rgba(content_color))
    end
end

function M.task(starts, ends, custom)
    check_next_talk()
    return ({
        next_talk = view_next_talk,
        other_talks = view_other_talks,
        talk_info = view_talk_info,
        room_info = view_room_info,
        all_talks = view_all_talks,
        info_bar = view_info_bar,
        clock = view_clock,
    })[custom.mode](starts, ends, custom)
end

return M
