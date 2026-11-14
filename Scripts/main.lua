-- AltermaticMenuPreview
--
-- Shows Altermatic material swaps (e.g. Shining Luckies) on the Pal status
-- screen's 3D preview (party and Palbox), which Altermatic itself does not
-- reach: it only alters Pals spawned in the world.
--
-- Reads the same files Altermatic does: Pal/Content/Paks/~mods/SwapJSON,
-- _LoadList.json and the packs it lists. For each "SkelMeshSwap" entry whose
-- CharacterID matches the shown Pal (and IsRarePal / Gender / SkinName /
-- ReqTrait, when given), each MatReplace slot index gets that material.
-- Entries that swap in a different model are skipped (materials only).
--
-- How (found with diagnostic probes): after WBP_PalStatus_C finishes setting
-- up the preview (OnCompletedCaptureActorSetup), the shown Pal is
-- LastHoveredPalHandle and the model is BP_PalMonsterCaptureSet_C.SkeletalMesh.
-- Materials in mod paks load through KismetSystemLibrary.LoadAsset_Blocking
-- (UE4SS's LoadAsset only sees the base game's asset registry), and their
-- textures are forced to full resolution (the preview is off-screen, so the
-- streamer would otherwise keep them blurry).
--
-- Remember to run SwapJSON/__Create_Load_List__.sh after adding packs.

local TAG = "[AltermaticMenuPreview] "
local STATUS_CLASS = "/Game/Pal/Blueprint/UI/PalStatus/WBP_PalStatus.WBP_PalStatus_C"
local HOOK_FN = STATUS_CLASS .. ":OnCompletedCaptureActorSetup"
local RECHECK_MS = 200

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print(TAG .. (ok and msg or tostring(fmt)) .. "\n")
end

local logged = {}
local function logOnce(key, fmt, ...)
    if logged[key] then return end
    logged[key] = true
    log(fmt, ...)
end

------------------------------------------------------------------------------
-- UObject helpers
------------------------------------------------------------------------------

local function unwrap(v)
    if type(v) ~= "userdata" then return v end
    local okg, getter = pcall(function() return v.get end)
    if okg and getter then
        local ok, inner = pcall(function() return v:get() end)
        if ok then return inner end
    end
    return v
end

local function valid(o)
    o = unwrap(o)
    if o == nil then return false end
    local ok, r = pcall(function() return o:IsValid() end)
    return ok and r == true
end

local function call(o, fn, ...)
    o = unwrap(o)
    if not valid(o) then return nil end
    local args = { ... }
    local ok, r = pcall(function() return o[fn](o, table.unpack(args)) end)
    if ok then return unwrap(r) end
    return nil
end

local function prop(o, name)
    o = unwrap(o)
    if not valid(o) then return nil end
    local ok, r = pcall(function() return o[name] end)
    if ok then return unwrap(r) end
    return nil
end

local function str(v)
    v = unwrap(v)
    if type(v) == "string" then return v end
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and s or nil
end

local function name(o)
    o = unwrap(o)
    if not valid(o) then return nil end
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    return ok and s or nil
end

local function className(o)
    return name(call(o, "GetClass")) or "?"
end

local function fullPath(o)
    -- "/Game/Path/Asset.Asset" from "Type /Game/Path/Asset.Asset"
    local n = call(o, "GetFullName")
    if type(n) ~= "string" then return nil end
    return (n:gsub("^%S+%s+", "", 1))
end

------------------------------------------------------------------------------
-- SwapJSON data
------------------------------------------------------------------------------

-- Minimal JSON decoder (objects, arrays, strings, numbers, true/false/null).
local function decodeJSON(s)
    local pos = 1
    if s:sub(1, 3) == "\239\187\191" then pos = 4 end -- UTF-8 BOM
    local function ws() pos = s:find("[^ \t\r\n]", pos) or (#s + 1) end
    local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
    local function parseString()
        pos = pos + 1 -- opening quote
        local buf = {}
        while true do
            local c = s:sub(pos, pos)
            if c == "" then error("unterminated string") end
            if c == '"' then pos = pos + 1 break end
            if c == "\\" then
                local n = s:sub(pos + 1, pos + 1)
                if n == "u" then
                    local cp = tonumber(s:sub(pos + 2, pos + 5), 16) or 63
                    buf[#buf + 1] = (utf8 and utf8.char(cp)) or "?"
                    pos = pos + 6
                else
                    buf[#buf + 1] = ESC[n] or n
                    pos = pos + 2
                end
            else
                local j = s:find('["\\]', pos) or (#s + 1)
                buf[#buf + 1] = s:sub(pos, j - 1)
                pos = j
            end
        end
        return table.concat(buf)
    end
    local parseValue
    parseValue = function()
        ws()
        local c = s:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local obj = {}
            ws()
            if s:sub(pos, pos) == "}" then pos = pos + 1 return obj end
            while true do
                ws()
                if s:sub(pos, pos) ~= '"' then error("expected key at " .. pos) end
                local k = parseString()
                ws()
                if s:sub(pos, pos) ~= ":" then error("expected ':' at " .. pos) end
                pos = pos + 1
                obj[k] = parseValue()
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return obj end
                if d ~= "," then error("expected ',' or '}' at " .. (pos - 1)) end
            end
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            ws()
            if s:sub(pos, pos) == "]" then pos = pos + 1 return arr end
            while true do
                arr[#arr + 1] = parseValue()
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return arr end
                if d ~= "," then error("expected ',' or ']' at " .. (pos - 1)) end
            end
        elseif c == '"' then
            return parseString()
        elseif s:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif s:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif s:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
            if not num or num == "" then error(("unexpected '%s' at %d"):format(c, pos)) end
            pos = pos + #num
            return tonumber(num)
        end
    end
    return parseValue()
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function ownRoot()
    local ok, info = pcall(debug.getinfo, ownRoot, "S")
    local src = ok and info and info.source and info.source:gsub("^@", "")
    return src and src:match("^(.*)[/\\][Ss]cripts[/\\]") or nil
end

local swapDir = nil
do
    local candidates = {}
    local root = ownRoot()
    local palRoot = root and root:match("^(.*)[/\\]Mods[/\\]NativeMods[/\\]")
    if palRoot then candidates[#candidates + 1] = palRoot .. "/Pal/Content/Paks/~mods/SwapJSON" end
    candidates[#candidates + 1] = "../../Content/Paks/~mods/SwapJSON"
    for _, c in ipairs(candidates) do
        if readFile(c .. "/_LoadList.json") then swapDir = c break end
    end
end

-- "/Game/X/Asset" -> "/Game/X/Asset.Asset" (object path, as GetFullName gives).
local function objectPath(p)
    if type(p) ~= "string" or p == "" then return nil end
    if p:match("%.[^/]+$") then return p end
    return p .. "." .. (p:match("([^/]+)$") or "")
end

local function packagePath(p)
    return p and (p:match("^([^.]+)") or p) or nil
end

-- lowercase CharacterID -> { entry, ... } in load-list order
local byId = {}
local entryCount, packCount = 0, 0

local function addEntry(raw, pack)
    if type(raw) ~= "table" or type(raw.CharacterID) ~= "string" then return end
    local mats = {}
    for _, m in ipairs(raw.MatReplace or {}) do
        local idx = tonumber(m.Index)
        local path = objectPath(m.MatPath)
        if idx and path then mats[#mats + 1] = { index = idx, path = path } end
    end
    local req = raw.ReqTrait
    if type(req) == "string" then req = { req } end
    local e = {
        id = raw.CharacterID,
        rare = raw.IsRarePal == true or (type(raw.IsRarePal) == "string" and raw.IsRarePal:lower() == "true"),
        gender = type(raw.Gender) == "string" and raw.Gender:lower() or nil,
        skin = type(raw.SkinName) == "string" and raw.SkinName:lower() or nil,
        req = type(req) == "table" and #req > 0 and req or nil,
        mesh = packagePath(raw.SkelMeshPath),
        mats = mats,
        pack = pack,
    }
    local key = e.id:lower()
    byId[key] = byId[key] or {}
    table.insert(byId[key], e)
    entryCount = entryCount + 1
end

if swapDir then
    local okL, list = pcall(decodeJSON, readFile(swapDir .. "/_LoadList.json") or "")
    if okL and type(list) == "table" and type(list.LoadList) == "table" then
        for _, packName in ipairs(list.LoadList) do
            if type(packName) == "string" and packName ~= "" then
                local text = readFile(swapDir .. "/" .. packName .. ".json")
                local okP, pack = false, nil
                if text then okP, pack = pcall(decodeJSON, text) end
                if okP and type(pack) == "table" and type(pack.SkelMeshSwap) == "table" then
                    packCount = packCount + 1
                    for _, raw in ipairs(pack.SkelMeshSwap) do addEntry(raw, pack.PackName or packName) end
                else
                    log("could not read pack %s.json (%s)", packName, tostring(text and pack or "file missing"))
                end
            end
        end
    else
        log("could not read _LoadList.json (%s)", tostring(list))
    end
end

------------------------------------------------------------------------------
-- The shown Pal
------------------------------------------------------------------------------

local GENDERS = { [1] = "male", [2] = "female" }

-- { species, skin, lucky, gender, passives = { lowercase name = true } }
local function describe(param)
    if not valid(param) then return nil end
    local species = str(call(param, "GetCharacterID"))
    if not species then return nil end
    local skin = str(call(param, "GetSkinName"))
    if skin == "None" or skin == "" then skin = nil end
    local passives = {}
    local list = call(param, "GetPassiveSkillList")
    if list ~= nil then
        pcall(function()
            list:ForEach(function(_, el)
                local n = str(el)
                if n then passives[n:lower()] = true end
            end)
        end)
    end
    local lucky = call(param, "IsRarePal") == true or passives["rare"] == true
    local g = call(param, "GetGender")
    local gender = type(g) == "number" and GENDERS[g] or nil
    return { species = species, skin = skin, lucky = lucky, gender = gender, passives = passives }
end

-- Like Altermatic: CharacterID must match exactly; the other keys are
-- conditions. Among matches, the one with the most conditions wins.
--
-- A Pal wearing an official skin only gets an entry made for that skin
-- (SkinName = the skin, or CharacterID = the skin name). Species entries are
-- not used for it: in the world Altermatic leaves skinned Pals as they are
-- (Shining Luckies lists this as a known issue), and the species' slot layout
-- may not fit the skin's materials. So the preview shows the skin, like the world.
local function findEntry(pal)
    local list
    if pal.skin then
        local skin = pal.skin:lower()
        list = {}
        for _, e in ipairs(byId[pal.species:lower()] or {}) do
            if e.skin == skin then list[#list + 1] = e end
        end
        for _, e in ipairs(byId[skin] or {}) do list[#list + 1] = e end
        if #list == 0 then
            logOnce("skin:" .. pal.species .. ":" .. skin,
                "%s wears skin %s and no pack has an entry for that skin; left as the skin", pal.species, pal.skin)
            return nil
        end
    else
        list = byId[pal.species:lower()]
        if not list then return nil end
    end
    local best, bestScore = nil, -1
    for _, e in ipairs(list) do
        local ok = true
        local score = 0
        if e.rare then
            if pal.lucky then score = score + 1 else ok = false end
        end
        if ok and e.gender and e.gender ~= "none" then
            if pal.gender == e.gender then score = score + 1 else ok = false end
        end
        if ok and e.skin then
            if pal.skin and pal.skin:lower() == e.skin then score = score + 1 else ok = false end
        end
        if ok and e.req then
            for _, t in ipairs(e.req) do
                if not pal.passives[tostring(t):lower()] then ok = false break end
            end
            if ok then score = score + 1 end
        end
        if ok and score > bestScore then best, bestScore = e, score end
    end
    return best
end

------------------------------------------------------------------------------
-- Material swapping
------------------------------------------------------------------------------

local missing = {}
local function loadMaterial(path)
    if missing[path] then return nil end
    local mat = StaticFindObject(path)
    if valid(mat) then return mat end
    local errs = {}

    -- 1. The engine's soft-reference loader (what blueprint mods use). UE4SS's
    --    own LoadAsset goes through the asset registry, which does not list
    --    assets that only exist in mod paks.
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if valid(ksl) then
        local ok, res = pcall(function()
            local sp = ksl:MakeSoftObjectPath(path)
            local soft = ksl:Conv_SoftObjPathToSoftObjRef(sp)
            return ksl:LoadAsset_Blocking(soft)
        end)
        if ok then
            mat = unwrap(res)
            if not valid(mat) then mat = StaticFindObject(path) end
            if valid(mat) then
                logOnce("loader:ksl", "loading Lucky materials through KismetSystemLibrary")
                return mat
            end
            errs[#errs + 1] = "LoadAsset_Blocking returned nothing"
        else
            errs[#errs + 1] = "KismetSystemLibrary: " .. tostring(res)
        end
    else
        errs[#errs + 1] = "KismetSystemLibrary not found"
    end

    -- 2. UE4SS LoadAsset, package path then object path.
    local package = path:match("^([^.]+)%.") or path
    for _, p in ipairs({ package, path }) do
        local ok, res = pcall(LoadAsset, p)
        if not ok then errs[#errs + 1] = "LoadAsset " .. p .. ": " .. tostring(res) end
        mat = StaticFindObject(path)
        if not valid(mat) and ok and valid(unwrap(res)) then mat = unwrap(res) end
        if valid(mat) then
            logOnce("loader:ue4ss", "loading Lucky materials through UE4SS LoadAsset")
            return mat
        end
    end
    missing[path] = true
    log("could not load %s (%s)", path, table.concat(errs, "; "))
    return nil
end

-- What this mod changed: material path -> true, and per mesh+slot the
-- stock material path, so a Pal without a swap can be put back exactly.
local ours = {}
local originals = {} -- meshFullName -> { [slot] = stock material path }

-- The preview mesh sits off-screen and is drawn by a scene capture, so the
-- texture streamer never asks for the high-resolution mips of textures only
-- it uses (the swapped-in ones). Force them resident on the textures themselves
-- and on the mesh.
local forcedTex = {}
local function forceTexturesResident(mat)
    local n = 0
    for _ = 1, 4 do
        if not valid(mat) then break end
        pcall(function()
            mat.TextureParameterValues:ForEach(function(_, el)
                local v = unwrap(el)
                local tex = unwrap(v.ParameterValue)
                local key = valid(tex) and fullPath(tex)
                if key and not forcedTex[key] then
                    forcedTex[key] = true
                    pcall(function() tex.bForceMiplevelsToBeResident = true end)
                    pcall(function() tex:SetForceMipLevelsToBeResident(3600.0, 0) end)
                    n = n + 1
                end
            end)
        end)
        mat = prop(mat, "Parent")
    end
    return n
end

local function forceMeshResident(mesh)
    pcall(function() mesh:SetTextureForceResidentFlag(true) end)
    pcall(function() mesh:PrestreamTextures(30.0, true, 0) end)
end

local function meshAssetPath(mesh)
    local asset = prop(mesh, "SkeletalMesh") or prop(mesh, "SkinnedAsset")
    return packagePath(fullPath(asset))
end

-- Put an entry's MatReplace materials on the preview mesh, by slot index.
local function applyEntry(mesh, entry)
    local count = call(mesh, "GetNumMaterials")
    if type(count) ~= "number" or count < 1 then return 0 end
    local meshKey = fullPath(mesh) or "?"
    local touched = 0
    for _, m in ipairs(entry.mats) do
        if m.index < count then
            local current = call(mesh, "GetMaterial", m.index)
            local curPath = fullPath(current)
            if curPath ~= m.path then
                local mat = loadMaterial(m.path)
                if mat and pcall(function() mesh:SetMaterial(m.index, mat) end) then
                    local forced = forceTexturesResident(mat)
                    if forced > 0 then
                        logOnce("forced:" .. m.path, "%s: forced %d texture(s) to full resolution",
                            m.path:match("([^.]+)$") or m.path, forced)
                    end
                    if curPath and not ours[curPath] then
                        originals[meshKey] = originals[meshKey] or {}
                        originals[meshKey][m.index] = curPath
                    end
                    ours[m.path] = true
                    touched = touched + 1
                end
            end
        else
            logOnce(("slot:%s:%d"):format(entry.id, m.index), "%s: slot %d does not exist on the preview (%d slots)",
                entry.id, m.index, count)
        end
    end
    if touched > 0 then forceMeshResident(mesh) end
    return touched
end

------------------------------------------------------------------------------
-- Status screen
------------------------------------------------------------------------------

local function captureActorsFor(species)
    local out = {}
    for _, cap in ipairs(FindAllOf("BP_PalMonsterCaptureSet_C") or {}) do
        if valid(cap) then
            local shown = str(prop(cap, "LoadingOriginalPalID"))
            if shown and shown:lower() == species:lower() then out[#out + 1] = cap end
        end
    end
    return out
end

local function processStatus(widget, pass)
    local handle = prop(widget, "LastHoveredPalHandle")
    local pal = describe(valid(handle) and call(handle, "TryGetIndividualParameter") or nil)
    if not pal then
        logOnce("nopal", "status screen: could not read the shown Pal")
        return
    end
    logOnce(("seen:%s:%s:%s"):format(pal.species, tostring(pal.skin), tostring(pal.lucky)),
        "status screen showing %s (skin=%s, lucky=%s)", pal.species, tostring(pal.skin), tostring(pal.lucky))

    local caps = captureActorsFor(pal.species)
    local entry = findEntry(pal)
    if not entry then
        for _, cap in ipairs(caps) do
            local mesh = prop(cap, "SkeletalMesh")
            if valid(mesh) then revertMesh(mesh) end
        end
        if pal.lucky then
            logOnce("noentry:" .. pal.species, "no swap entry for %s", pal.species)
        end
        return
    end
    if #caps == 0 then
        logOnce("nocap:" .. pal.species, "preview for %s not found", pal.species)
        return
    end
    for _, cap in ipairs(caps) do
        local mesh = prop(cap, "SkeletalMesh")
        if valid(mesh) then
            local shownMesh = meshAssetPath(mesh)
            if entry.mesh and shownMesh and entry.mesh:lower() ~= shownMesh:lower() then
                logOnce("meshswap:" .. entry.id,
                    "%s: pack %s swaps the model (%s); only material swaps are supported, skipped",
                    entry.id, tostring(entry.pack), entry.mesh)
            else
                local touched = applyEntry(mesh, entry)
                if touched > 0 then
                    logOnce(("applied:%s:%s"):format(pal.species, pass),
                        "%s preview: %d slot(s) from pack %s (pass %s)", pal.species, touched, tostring(entry.pack), pass)
                end
            end
        end
    end
end

local function safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then logOnce("err:" .. tostring(err), "error: %s", tostring(err)) end
end

local hookInstalled = false
local function installHook()
    if hookInstalled then return end
    if not valid(StaticFindObject(STATUS_CLASS)) then return end
    -- A pre-hook: this UE4SS build does not run post-hooks on blueprint
    -- functions. The work is queued for the next game-thread tick, which is
    -- after the game's own setup in this function has finished.
    local fired = 0
    local ok, err = pcall(RegisterHook, HOOK_FN, function(ctx)
        local widget = unwrap(ctx)
        fired = fired + 1
        if fired <= 3 then log("status screen preview ready (#%d)", fired) end
        local queued = pcall(ExecuteInGameThread, function()
            if valid(widget) then safe(processStatus, widget, "1") end
        end)
        if not queued then safe(processStatus, widget, "1") end
        pcall(ExecuteInGameThreadWithDelay, RECHECK_MS, function()
            if valid(widget) then safe(processStatus, widget, "2") end
        end)
    end)
    if ok then
        hookInstalled = true
        log("hooked status screen preview")
    else
        log("could not hook %s: %s", HOOK_FN, tostring(err))
    end
end

------------------------------------------------------------------------------
-- Start
------------------------------------------------------------------------------

if not swapDir then
    log("SwapJSON folder (with _LoadList.json) not found; nothing to do")
    return
end
if entryCount == 0 then
    log("no swap entries loaded from %s; run __Create_Load_List__.sh?", swapDir)
    return
end

pcall(NotifyOnNewObject, STATUS_CLASS, function()
    if not hookInstalled then
        pcall(ExecuteInGameThread, function() safe(installHook) end)
    end
end)
pcall(ExecuteInGameThread, function() safe(installHook) end)

log("loaded %d swap entries from %d pack(s) in %s", entryCount, packCount, swapDir)
