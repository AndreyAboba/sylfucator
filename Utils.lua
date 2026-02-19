-- ============================================================
-- Utils.lua
-- FIX: не делаем local алиасы bit32/math/string/table
-- они уже есть в SyllinseEnv через injectGlobals()
-- просто используем их напрямую
-- ============================================================
print('utils v1')
rv = function()
    local fp = {"l","I","ll","lI","Il","II","lll","III","llI","IlI"}
    local rp = {"l","I","1","O","0","ll","lI","Il","lI1","Il0","llI"}
    local r = {fp[math.random(1, #fp)]}
    for i = 2, math.random(8, 16) do
        r[i] = rp[math.random(1, #rp)]
    end
    return table.concat(r)
end

local ALPHA  = "SyllinseABCDEFGHJKMNPQRTUVWXZ"
local ALPHAN = "SyllinseABCDEFGHJKMNPQRTUVWXZ0123456789"

sylRand = function(n)
    local r = {}
    local fi = math.random(1, #ALPHA)
    r[1] = ALPHA:sub(fi, fi)
    for i = 2, n + 1 do
        local x = math.random(1, #ALPHAN)
        r[i] = ALPHAN:sub(x, x)
    end
    return "S_" .. table.concat(r)
end

genBuildId = function()
    return sylRand(12)
end

mba = function(n)
    n = math.floor(n or 0) % (2^32)
    if n < 0 then n = n + 2^32 end
    n = math.floor(n)
    local a = math.random(1, 32767)
    local b = bit32.bxor(n, a)
    return "(bit32.bxor(" .. a .. "," .. b .. "))"
end

tbl = function(t)
    local p = {}
    for i, v in ipairs(t) do
        p[i] = tostring(v)
    end
    return "{" .. table.concat(p, ",") .. "}"
end

encStr = function(s)
    if #s == 0 then return '""' end

    local k1 = {}
    for i = 1, #s do
        k1[i] = math.random(1, 255)
        if k1[i] == 0 then k1[i] = 1 end
    end

    local k2 = math.random(1, 255)
    if k2 == 0 then k2 = 1 end

    local enc = {}
    for i = 1, #s do
        enc[i] = bit32.bxor(s:byte(i), k1[i])
    end

    local ek = {}
    for i = 1, #k1 do
        ek[i] = bit32.bxor(k1[i], k2)
    end

    return ("(function()"
        .. "local _e=%s "
        .. "local _k=%s "
        .. "local _l=%s "
        .. "local _r={} "
        .. "for _i=1,#_e do "
        .. "_r[_i]=string.char(bit32.bxor(_e[_i],bit32.bxor(_k[_i],_l))) "
        .. "end "
        .. "return table.concat(_r) "
        .. "end)()"):format(tbl(enc), tbl(ek), mba(k2))
end

junk = function()
    local r = math.random(1, 4)
    if r == 1 then
        return "local " .. rv()
            .. " = bit32.bxor("
            .. math.random(1, 9999) .. ","
            .. math.random(1, 9999) .. ")"
    elseif r == 2 then
        return "local " .. rv()
            .. " = math.floor("
            .. math.random(1, 9999) .. ")"
    elseif r == 3 then
        local v = rv()
        return "local " .. v .. "=" .. math.random(1, 9999)
            .. " if " .. v
            .. "<-999999 and(function()return false end)()"
            .. "then error(" .. encStr("_") .. ") end"
    else
        return "local " .. rv()
            .. " = ("
            .. math.random(1, 9999) .. "~="
            .. math.random(10000, 19999) .. ")"
    end
end

junkN = function(n)
    local p = {}
    for i = 1, n do
        p[i] = junk()
    end
    return table.concat(p, "\n")
end

OP = {
    LOADK=1,     LOADNIL=2,   LOADBOOL=3,  MOVE=4,
    GETGLOBAL=5, SETGLOBAL=6, GETTABLE=7,  SETTABLE=8,
    ADD=9,       SUB=10,      MUL=11,      DIV=12,
    MOD=13,      POW=14,      IDIV=15,
    CONCAT=16,   UNM=17,      NOT=18,      LEN=19,
    EQ=20,       LT=21,       LE=22,
    NEWTABLE=23,
    BAND=24,     BOR=25,      BXOR=26,     SHL=27,
    SHR=28,      BNOT=29,
    TEST=30,     JMP=31,
    CALL=32,     TAILCALL=33, RETURN=34,
    CLOSURE=35,  VARARG=37,
    FORPREP=38,  FORLOOP=39,  TFORLOOP=40,
    NOOP=41,     JUNK1=42,    JUNK2=43,    SETLIST=44,
    SELFCALL=45,
}

makeRA = function()
    local top    = 0
    local maxTop = 0
    local ra     = {}

    function ra:alloc()
        top = top + 1
        if top > maxTop then maxTop = top end
        return top
    end

    function ra:allocN(n)
        local base = top + 1
        top = top + n
        if top > maxTop then maxTop = top end
        return base
    end

    function ra:setTop(level)
        top = level
    end

    function ra:getTop()
        return top
    end

    function ra:getMax()
        return maxTop
    end

    return ra
end

print("[Syllinse] Utils загружен: rv=" .. type(rv) .. " mba=" .. type(mba) .. " OP=" .. type(OP))
