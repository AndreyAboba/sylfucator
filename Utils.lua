-- ============================================================
-- Utils.lua
-- Утилиты обфускатора — rv, sylRand, mba, encStr, junkN
-- Все функции пишутся без local — видны всем модулям через SyllinseEnv
-- ============================================================

local bit32_bxor  = bit32.bxor
local math_floor  = math.floor
local math_random = math.random
local string_char = string.char
local table_concat = table.concat

-- ============================================================
-- ГЕНЕРАТОР СЛУЧАЙНЫХ ИМЁН (стиль l/I/0/O)
-- ============================================================
rv = function()
    local fp = {"l","I","ll","lI","Il","II","lll","III","llI","IlI"}
    local rp = {"l","I","1","O","0","ll","lI","Il","lI1","Il0","llI"}
    local r = {fp[math_random(1, #fp)]}
    for i = 2, math_random(8, 16) do
        r[i] = rp[math_random(1, #rp)]
    end
    return table_concat(r)
end

-- ============================================================
-- ГЕНЕРАТОР ИМЁН В СТИЛЕ Syllinse (S_XXXX)
-- ============================================================
local ALPHA  = "SyllinseABCDEFGHJKMNPQRTUVWXZ"
local ALPHAN = "SyllinseABCDEFGHJKMNPQRTUVWXZ0123456789"

sylRand = function(n)
    local r = {}
    local fi = math_random(1, #ALPHA)
    r[1] = ALPHA:sub(fi, fi)
    for i = 2, n + 1 do
        local x = math_random(1, #ALPHAN)
        r[i] = ALPHAN:sub(x, x)
    end
    return "S_" .. table_concat(r)
end

genBuildId = function()
    return sylRand(12)
end

-- ============================================================
-- MBA — Mixed Boolean Arithmetic обфускация числа
-- Превращает число N в выражение bit32.bxor(A, B)
-- где A случайное, B = N xor A
-- FIX: приводим к uint32 перед bxor чтобы не было отрицательных
-- ============================================================
mba = function(n)
    n = math_floor(n or 0) % (2^32)
    if n < 0 then n = n + 2^32 end
    n = math_floor(n)
    local a = math_random(1, 32767)
    local b = bit32_bxor(n, a)
    return "(bit32.bxor(" .. a .. "," .. b .. "))"
end

-- ============================================================
-- СЕРИАЛИЗАЦИЯ ТАБЛИЦЫ ЧИСЕЛ В СТРОКУ {n1,n2,...}
-- Используется внутри encStr
-- ============================================================
tbl = function(t)
    local p = {}
    for i, v in ipairs(t) do
        p[i] = tostring(v)
    end
    return "{" .. table_concat(p, ",") .. "}"
end

-- ============================================================
-- ШИФРОВАНИЕ СТРОКИ
-- Схема:
--   1. Для каждого символа генерируем случайный ключ k1[i]
--   2. Шифруем: enc[i] = char[i] XOR k1[i]
--   3. Шифруем ключи: ek[i]  = k1[i] XOR k2
--   4. k2 обфусцируем через mba()
--   5. Декодер восстанавливает: char[i] = enc[i] XOR (ek[i] XOR k2)
-- ============================================================
encStr = function(s)
    if #s == 0 then return '""' end

    local k1 = {}
    for i = 1, #s do
        k1[i] = math_random(1, 255)
        if k1[i] == 0 then k1[i] = 1 end
    end

    local k2 = math_random(1, 255)
    if k2 == 0 then k2 = 1 end

    local enc = {}
    for i = 1, #s do
        enc[i] = bit32_bxor(s:byte(i), k1[i])
    end

    local ek = {}
    for i = 1, #k1 do
        ek[i] = bit32_bxor(k1[i], k2)
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

-- ============================================================
-- ГЕНЕРАТОР МУСОРНОГО КОДА
-- Типы мусора:
--   1. bit32.bxor(a, b)
--   2. math.floor(n)
--   3. переменная с условием которое никогда не выполнится
--   4. простое сравнение
-- ============================================================
junk = function()
    local r = math_random(1, 4)
    if r == 1 then
        return "local " .. rv()
            .. " = bit32.bxor("
            .. math_random(1, 9999) .. ","
            .. math_random(1, 9999) .. ")"

    elseif r == 2 then
        return "local " .. rv()
            .. " = math.floor("
            .. math_random(1, 9999) .. ")"

    elseif r == 3 then
        local v = rv()
        return "local " .. v .. "=" .. math_random(1, 9999)
            .. " if " .. v
            .. "<-999999 and(function()return false end)()"
            .. "then error(" .. encStr("_") .. ") end"

    else
        return "local " .. rv()
            .. " = ("
            .. math_random(1, 9999) .. "~="
            .. math_random(10000, 19999) .. ")"
    end
end

junkN = function(n)
    local p = {}
    for i = 1, n do
        p[i] = junk()
    end
    return table_concat(p, "\n")
end

-- ============================================================
-- ТАБЛИЦА ОПКОДОВ — общая для Compiler, Serializer, VMGenerator
-- ============================================================
OP = {
    LOADK=1,    LOADNIL=2,   LOADBOOL=3,  MOVE=4,
    GETGLOBAL=5, SETGLOBAL=6, GETTABLE=7,  SETTABLE=8,
    ADD=9,      SUB=10,      MUL=11,      DIV=12,
    MOD=13,     POW=14,      IDIV=15,
    CONCAT=16,  UNM=17,      NOT=18,      LEN=19,
    EQ=20,      LT=21,       LE=22,
    NEWTABLE=23,
    BAND=24,    BOR=25,      BXOR=26,     SHL=27,
    SHR=28,     BNOT=29,
    TEST=30,    JMP=31,
    CALL=32,    TAILCALL=33, RETURN=34,
    CLOSURE=35, VARARG=37,
    FORPREP=38, FORLOOP=39,  TFORLOOP=40,
    NOOP=41,    JUNK1=42,    JUNK2=43,    SETLIST=44,
    SELFCALL=45,
}

-- ============================================================
-- REGISTER ALLOCATOR
-- Linear stack allocator — alloc/free через setTop
-- ============================================================
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
