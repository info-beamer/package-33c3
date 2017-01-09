local api, CHILDS, CONTENTS = ...

local json = require "json"
local scissors = sys.get_ext "scissors"

local font
local background
local color
local speed
local margin

local M = {}

-- { source: { text1, text2, text3, ...} }
local content = {__myself__ = {}}

local function mix_content()
    local out = {}
    local offset = 1
    while true do
        local added = false
        for tile, items in pairs(content) do
            if items[offset] then
                out[#out+1] = items[offset]
                added = true
            end
        end
        if not added then
            break
        end
        offset = offset + 1
    end
    return out
end

local feed = util.generator(mix_content).next

api.add_listener("scroller", function(tile, value)
    print("got new scroller content from " .. tile)
    content[tile] = value
    -- pp(content)
end)

local items = {}
local current_left = 0
local last = sys.now()

local function draw_scroller(x, y, w, h)
    scissors.set(x, y, x+w, y+h)

    local now = sys.now()
    local delta = now - last
    last = now
    local advance = delta * speed

    local idx = 1
    local x = current_left

    local function prepare_image(obj)
        if not obj then
            return
        end
        local ok, obj_copy = pcall(obj.copy, obj)
        if ok then
            return resource.load_image{
                file = obj_copy,
                mipmap = true,
            }
        else
            return obj
        end
    end

    while x < WIDTH do
        if idx > #items then
            local item = feed()
            if item then
                items[#items+1] = {
                    text = item.text .. "    -    ",
                    image = prepare_image(item.image)
                }
            else
                items[#items+1] = {
                    text = "                      ",
                }
            end
        end

        local item = items[idx]

        if item.image then
            local state, img_w, img_h = item.image:state()
            if state == "loaded" then
                local img_max_height = h
                local proportional_width = img_max_height / img_h * img_w
                item.image:draw(x, y, x+proportional_width, y+img_max_height)
                x = x + proportional_width + 30
            end
        end

        local text_width = font:write(
            x, y+3, item.text, h-6, 
            color.r, color.g, color.b, color.a
        )
        x = x + text_width

        if x < 0 then
            assert(idx == 1)
            if item.image then
                item.image:dispose()
            end
            table.remove(items, idx)
            current_left = x
        else
            idx = idx + 1
        end
    end

    scissors.disable()

    current_left = current_left - advance
end

function M.updated_config_json(config)
    font = resource.load_font(api.localized(config.font.asset_name))
    background = resource.load_image(api.localized(config.background.asset_name))
    color = config.color
    speed = config.speed
    margin = config.margin

    content.__myself__ = {}
    local texts = content.__myself__
    for idx = 1, #config.texts do
        texts[#texts+1] = {text = config.texts[idx].text}
    end
end

function M.task(starts, ends, custom)
    for now, x1, y1, x2, y2 in api.from_to(starts, ends) do
        background:draw(x1, y1-margin, x2, y2+margin, custom.blend or 1.0)
        draw_scroller(x1, y1, x2-x1, y2-y1)
    end
end

return M
