local BASE = "https://raw.githubusercontent.com/TRENDDYAMM/stealanegg/main/"

local files = {
    "main.lua",
    "main2.lua",
    "panelpos.lua",
    "hop.lua",
    "holy.lua",
    "fps.lua",
}

for _, name in ipairs(files) do
    local ok, err = pcall(function()
        loadstring(game:HttpGet(BASE .. name))()
    end)
    if not ok then warn("Failed to load " .. name .. ": " .. tostring(err)) end
end