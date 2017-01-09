local api, CHILDS, CONTENTS = ...

local json = require "json"
local utils = require(api.localized "utils")
local anims = require(api.localized "anims")

local show_logo = true
local char_per_sec = 7
local include_in_scroller = true
local content_box, profile_box
local content_color, profile_color
local font
local margin = 10
local logo = resource.load_image{
    file = api.localized "twitter-logo.png"
}

local playlist = {}

local M = {}

function M.updated_tweets_json(tweets)
    playlist = {}

    local scroller = {}
    for idx = 1, #tweets do
        local tweet = tweets[idx]

        local ok, profile, image, video, media_time

        ok, profile = pcall(resource.open_file, api.localized(tweet.profile_image))
        if not ok then
            print("cannot use this tweet. profile image missing", profile)
            profile = nil
        end

        if #tweet.images > 0 then
            -- TODO: load more than only the first image
            ok, image = pcall(resource.open_file, api.localized(tweet.images[1]))
            if not ok then
                print("cannot open image", image)
                image = nil
            end
        end

        if tweet.video then
            ok, video = pcall(resource.open_file, api.localized(tweet.video.filename))
            if ok then
                media_time = tweet.video.duration
            else
                print("cannot open video", video)
                video = nil
            end
        end
            
        if profile then
            playlist[#playlist+1] = {
                screen_name = tweet.screen_name,
                name = tweet.name,
                lines = tweet.lines,
                profile = profile,
                image = image,
                video = video,
                media_time = media_time,
                created_at = tweet.created_at,
            }

            if include_in_scroller then
                scroller[#scroller+1] = {
                    text = "@" .. tweet.screen_name .. ": " .. tweet.text,
                    image = profile,
                }
            end
        end
    end

    api.update_data("scroller", scroller)
end

function M.updated_config_json(config)
    print "config updated"

    include_in_scroller = config.include_in_scroller

    if config.profile_box.asset_name == "empty.png" then
        profile_box = nil
    else
        profile_box = resource.load_image(api.localized(config.profile_box.asset_name))
    end

    if config.content_box.asset_name == "empty.png" then
        content_box = nil
    else
        content_box = resource.load_image(api.localized(config.content_box.asset_name))
    end

    show_logo = config.show_logo
    font = resource.load_font(api.localized(config.font.asset_name))
    content_color = config.content_color
    profile_color = config.profile_color
    margin = config.margin

    node.gc()
end

local tweet_gen = util.generator(function()
    return playlist
end)

function M.task(starts, ends)
    local tweet = tweet_gen.next()

    local profile = resource.load_image{
        file = tweet.profile:copy(),
        mipmap = true,
    }

    api.wait_t(starts-2.5)

    local image, video

    if tweet.image then
        image = resource.load_image{
            file = tweet.image:copy(),
        }
    end

    if tweet.video then
        video = resource.load_video{
            file = tweet.video:copy(),
            looped = true,
            paused = true,
        }
    end

    api.wait_t(starts-0.3)

    local age = os.time() - tweet.created_at
    if age < 100 then
        age = string.format("%ds", age)
    elseif age < 3600 then
        age = string.format("%dm", age/60)
    elseif age < 86400 then
        age = string.format("%dh", age/3600)
    else
        age = string.format("%dd", age/86400)
    end

    local a = anims.Area(1920, 1080)

    local S = starts
    local E = ends

    local function mk_profile_box(x, y)
        local name = tweet.name
        local info = "@"..tweet.screen_name..", "..age.." ago"

        if profile_box then
            local profile_width = math.max(
                font:width(name, 70),
                font:width(info, 40)
            )
            a.add(anims.moving_image_raw(S,E, profile_box,
                x, y, x+140+profile_width+2*margin, y+80+40+2*margin, 1
            ))
        end
        a.add(anims.moving_font(S, E, font, x+140+margin, y+margin, name, 70,
            profile_color.r, profile_color.g, profile_color.b, profile_color.a
        ))
        a.add(anims.moving_font(S, E, font, x+140+margin, y+75+margin, info, 40,
            profile_color.r, profile_color.g, profile_color.b, profile_color.a*0.8
        )); S=S+0.1;
        -- a.add(anims.tweet_profile(S, E, x+margin, y+margin, profile, 120))
        a.add(anims.moving_image_raw(S,E, profile,
            x+margin, y+margin, x+margin+120, y+margin+120, 1
        ))
    end

    local function mk_content_box(x, y)
        if content_box then
            local text_width = 0
            for idx = 1, #tweet.lines do
                local line = tweet.lines[idx]
                text_width = math.max(text_width, font:width(line, 80))
            end
            a.add(anims.moving_image_raw(S,E, content_box,
                x, y, x+text_width+2*margin, y+#tweet.lines*80+2*margin, 1
            ))
        end
        y = y + margin
        for idx = 1, #tweet.lines do
            local line = tweet.lines[idx]
            a.add(anims.moving_font(S, E, font, x+margin, y, line, 80,
                content_color.r, content_color.g, content_color.b, content_color.a
            )); S=S+0.1; y=y+80
        end
    end

    local obj = video or image

    if obj then
        local width, height = obj:size()
        print("ASSET SIZE", width, height, obj)
        local x1, y1, x2, y2 = util.scale_into(1920, 1080, width, height)
        print(x1, y1, x2, y2)
        a.add(anims.moving_image_raw(S,E, obj,
            x1, y1, x2, y2, 1
        ))
        mk_content_box(10, 1080 - #tweet.lines * 80 - 10 - 2*margin)
        mk_profile_box(10, 10)
    else
        mk_content_box(10, 300)
        mk_profile_box(10, 10)
    end

    if show_logo then
        a.add(anims.logo(S, E, 1920-130, 1080-130, logo, 100))
    end

    for now, x1, y1, x2, y2 in api.from_to(starts, ends) do
        if video then
            video:start()
        end
        a.draw(now, x1, y1, x2, y2)
    end

    profile:dispose()

    if image then
        image:dispose()
    end

    if video then
        video:dispose()
    end
end

return M
