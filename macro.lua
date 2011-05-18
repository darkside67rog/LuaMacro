----------------------------------------------
-- LuaMacro 2, a macro-preprocessor for Lua.
-- Unlike LuaMacro 1.x, it does not depend on the token-filter patch and generates
-- Lua code which can be printed out or compiled directly. C-style macros are easy, but LM2
-- allows for macros that can read their own input and generate output using Lua code.
-- New in this release are lexically-scoped macros.
-- The Lua Lpeg Lexer is by Peter Odding.
-- Steve Donovan, 2011
-- @module macro
-- @alias M

local macro = {}
local M = macro
local lexer = require 'macro.lexer'
local scan_lua = lexer.scan_lua
local append = table.insert
local setmetatable = setmetatable


local TokenList = {}
TokenList.__index = TokenList

local function TL (tl)
    return setmetatable(tl or {},TokenList)
end

-- token-getting helpers

--- get a delimited list of token lists.
-- Typically used for grabbing argument lists like ('hello',a+1,fred(c,d)); will count parens
-- so that the delimiter (usually a comma) is ignored inside sub-expressions. You must have
-- already read the start token of the list, e.g. open parentheses. It will eat the end token
-- and return the list of TLs, plus the end token. Based on similar code in Penlight's
-- `pl.lexer` module.
-- @param tok the token stream
-- @param endt the end token (default ')')
-- @param delim the delimiter (default ',')
-- @return list of token lists
-- @return end token in form {type,value}
function M.get_list(tok,endtoken,delim)
    endtoken = endtoken or ')'
    delim = delim or ','
    local parm_values = {}
    local level = 1 -- used to count ( and )
    local tl = TL()
    local function tappend (tl,t,val)
        val = val or t
        append(tl,{t,val})
    end
    local is_end
    if type(endtoken) == 'function' then
        is_end = endtoken
    elseif endtoken == '\n' then
        is_end = function(t,val)
            return t == 'space' and val:find '\n'
        end
    else
        is_end = function (t)
            return t == endtoken
        end
    end
    local token,value = tok()
    if is_end(token,value) then return {} end
    if token == 'space' then
        token,value = tok()
    end
    while true do
        if not token then return nil,'unexpected end of list' end -- end of stream is an error!
        if is_end(token,value) and level == 1 then
            append(parm_values,tl)
            break
        elseif token == '(' then
            level = level + 1
            tappend(tl,'(')
        elseif token == ')' then
            level = level - 1
            if level == 0 then -- finished with parm list
                append(parm_values,tl)
                break
            else
                tappend(tl,')')
            end
        elseif token == '{' then
            level = level + 1
            tappend(tl,'{')
        elseif token == '}' then
            level = level - 1
            tappend(tl,'}')
        elseif token == delim and level == 1 then
            append(parm_values,tl) -- a new parm
            tl = TL()
        else
            tappend(tl,token,value)
        end
        token,value=tok()
    end
    return parm_values,{token,value}
end

function M.upto_keywords (k1,k2)
    return function(t,v)
        return t == 'keyword' and (v == k1 or v == k2)
    end,''
end

-- create a token iterator out of a token list
local function scan_iter (tlist)
    local i,n = 1,#tlist
    return function()
        local tv = tlist[i]
        if tv == nil then return nil end
        i = i + 1
        return tv[1],tv[2]
    end
end


function M.get_upto(tok,k1,k2)
    local endt = k1
    if k1:match '^%a+$' then
        endt = M.upto_keywords(k1,k2)
    end
    local ltl = M.get_list(tok,endt,'')
    M.assert(ltl ~= nil and #ltl > 0,'failed to grab tokens')
    return ltl[1]
end

function M.tnext(get)
    local t,v = get()
    while t == 'space' or t == 'comment' do
        t,v = get()
    end
    return t,v
end
local tnext = M.tnext

function M.get_name(tok)
    local t,v = tnext(tok)
    M.assert(t == 'iden','expecting name')
    return v
end

function M.get_number(tok)
    local t,v = tnext(tok)
    M.assert(t == 'number','expecting number')
    return tonumber(v)
end

--- get a delimited list of names.
-- works like get_list.
-- @param tok the token stream
-- @param endt the end token (default ')')
-- @param delim the delimiter (default ',')
-- @see get_list
function M.get_names(tok,endt,delim)
    local ltl,err = M.get_list(tok,endt,delim)
    if not ltl then error('get_names: '..err) end
    local names = {}
    -- get_list() will return {{}} for an empty list of tlists
    for i,tl in ipairs(ltl) do
        local tv = tl[1]
        if tv then names[i] = tv[2] end
    end
    return names
end

--- get the next string from the token stream.
-- Will skip space.
function M.get_string(tok)
    local t,v = M.expecting(tok,"string")
    return v:sub(2,-2)
end

--- assert that the next token has the given type.
-- @param type a token type ('iden','string',etc)
function M.expecting (tok,type,value)
    local t,v = tnext(tok)
    if t ~= type then M.error ("expected "..type.." got "..t) end
    if value then
        if v ~= value then M.error("expected "..value.." got "..v) end
    end
    return t,v
end

local Getter = {
    string = M.get_string,
    names = M.get_names,
    list = M.get_list,
    next = M.tnext,
    name = M.get_name,
    number = M.get_number,
    upto = M.get_upto,
    expecting = M.expecting
}

local GetterMT = {
    __index = Getter,
    __call = function(self)
        return self.fun()
    end
}

local function make_getter (get)
    return setmetatable({fun=get},GetterMT)
end

function M.Getter(tl)
    return make_getter(scan_iter(tl))
end

local function extract (tl)
    local tk = tl[1]
    if tk[1] == 'space' then
        tk = tl[2]
    end
    return tk
end

function TokenList.get_iden (tl)
    local tk = extract(tl)
    M.assert(tk[1]=='iden','expecting identifier')
    return tk[2]
end

function TokenList.get_number(tl)
    local tk = extract(tl)
    M.assert(tk[1]=='number','expecting number')
    return tonumber(tk[2])
end

function TokenList.get_string(tl)
    local tk = extract(tl)
    M.assert(tk[1]=='string')
    return tk[2]:sub(2,-2) -- watch out! what about long string literals??
end

-- token-putting helpers
local comma,space = {',',','},{'space',' '}

function M.put_name(res,name,no_space)
    append(res,{'iden',name})
    if not no_space then
        append(res,space)
    end
    return res
end

function M.put_string(res,name)
    append(res,{'string','"'..name..'"'})
    return res
end

function M.put_number(res,val)
    append(res,{'number',val})
    return res
end

--- put out a list of names, separated by commas.
-- @param res output token list
-- @param names a list of strings
function M.put_names(res,names)
    for i = 1,#names do
        M.put_name(res,names[i],true)
        if i ~= #names then append(res,comma) end
    end
    return res
end

--- put out a token list.
-- @param res output token list
-- @param names a token list
function M.put_tokens(res,tl)
    for j = 1,#tl do
        append(res,tl[j])
    end
    return res
end

function TokenList.__tostring(tl)
    local res = {}
    for j = 1,#tl do
        append(res,tl[j][2])
    end
    return table.concat(res)
end

--- put out a list of token lists, separated by commas.
-- @param res output token list
-- @param names a list of strings
function M.put_list(res,ltl)
    for i = 1,#ltl do
        M.put_tokens(res,ltl[i])
        if i ~= #ltl then append(res,comma) end
    end
    return res
end

--- put out a space token.
-- @param res output token list
-- @param space a string containing only whitespace (default ' ')
function M.put_space(res,space)
    append(res,{'space',space or ' '})
    return res
end

--- put out a keyword token.
-- @param res output token list
-- @param keyw a Lua keyword
function M.put_keyword(res,keyw)
    append(res,{'keyword',keyw})
    append(res,space)
    return res
end

--- put out a operator token.
-- @param res output token list
-- @param keyw an operator string
function M.put(res,t,v)
    append(res,{t,v or t})
    return res
end

TokenList.__call = function(obj,...)
    return M.put(obj,...)
end
TokenList.keyword = M.put_keyword
TokenList.space = M.put_space
TokenList.list = M.put_list
TokenList.names = M.put_names
TokenList.tokens = M.put_tokens
TokenList.name = M.put_name
TokenList.string = M.put_string
TokenList.number = M.put_number

local make_putter = TL

M.Putter = make_putter

-- given a token list, a set of formal arguments and the actual arguments,
-- return a new token list where the formal arguments have been replaced
-- by the actual arguments
local function substitute (tl,parms,args)
    local append,put_tokens = table.insert,M.put_tokens
    local parm_map = {}
    for i,name in ipairs(parms) do
        parm_map[name] = args[i]
    end
    local res = {}
    for _,tv in ipairs(tl) do
        local t,v = tv[1],tv[2]
        if t == 'iden' then
            local pval = parm_map[v]
            if pval then
                put_tokens(res,pval)
            else
                append(res,tv)
            end
        else
            append(res,tv)
        end
    end
    return res
end

function M.copy_tokens(tok,pred)
    local res = {}
    local t,v = tok()
    while t and not (pred and pred(t,v)) do
        append(res,{t,v})
        t,v = tok()
    end
    return res
end

function M.define_tokens(extra)
    lexer.add_extra_tokens(extra)
end

local imacros,smacros = {},{}

M.macro_table = imacros

--- define a macro using a specification string and optional function.
-- The specification looks very much like a C preprocessor macro: the name,
-- followed by an optional formal argument list (_no_ space after name!) and
-- the substitution. e.g 'answer 42' or 'sqr(x) ((x)*(x))'
--
-- If there is no substitution, then the second argument must be a function which
-- will be evaluated for the actual substitution.
-- @param macstr
-- @param subst_fn the optional substitution function
function M.define(macstr,subst_fn)
    local tok,t,macname,parms,parm_map
    local mtbl
    tok = scan_lua(macstr)
    t,macname = tok()
    if t == 'iden' then mtbl = imacros
    elseif t ~= 'string' and t ~= 'number' and t ~= 'keyword' then
        mtbl = smacros
    else
        error("a macro cannot be of type "..t)
    end
    t = tok()
    if t == '(' then
        parms = M.get_names(tok)
    end
    mtbl[macname] = {
        name = macname,
        subst = subst_fn or M.copy_tokens(tok),
        parms = parms
    }
end

function M.set_macro(name,subst,parms)
    local macros
    if name:match '^[_%a][_%w]*$' then
        macros = imacros
    else
        macros = smacros
    end
    if subst == nil then
        macros[name] = nil
        return
    end
    local last = macros[name]
    if type(subst) ~= 'table' or not subst.name then
        subst = {
            name = name,
            subst = subst,
            parms = parms
        }
    end
    macros[name] = subst
    return last
end

function M.set_scoped_macro (name,subst,parms)
    local old_value = M.set_macro(name,subst,parms)
    M.block_handler(-1,function()
        M.set_macro(name,old_value)
    end)
end

--- get the value of a macro. The macro substitution must either be a
-- a string or a single token.
-- @param name existing macro name
-- @return a string value, or nil if the macro does not exist.
function M.get_macro_value(name)
    local mac = imacros[name]
    if not mac then return nil end
    if type(mac.subst) == 'table' then
        return mac.subst[1][2]
    else
        return mac.subst
    end
end

local function get_macro (mac, no_error)
    local macro = imacros[mac]
    if not macro and not no_error then
        M.error("macro "..mac.." is not defined")
    end
    return macro
end

local push,pop = table.insert,table.remove

function M.push_macro_stack (name,value)
    local macro = get_macro(name)
    macro.stack = macro.stack or {}
    push(macro.stack,value)
end

function M.pop_macro_stack (name)
    local macro = get_macro(name)
    if macro.stack and #macro.stack > 0 then
        return pop(macro.stack)
    end
end

function M.value_of_macro_stack (name)
    local macro = get_macro(name,true)
    if not macro then return nil end
    if macro.stack and #macro.stack > 0 then
        return macro.stack[#macro.stack]
    end
end

local keywords = {
    ['do'] = 'open', ['then'] = 'open', ['else'] = 'open', ['function'] = 'open',
    ['repeat'] = 'open';
    ['end'] = 'close', ['until'] = 'close',['elseif'] = 'close'
}

local block_handlers,keyword_handlers = {},{}
local level = 1

--- specify a block handler at a given level.
function M.block_handler (lev,action)
    lev = lev + level
    if not block_handlers[lev] then
        block_handlers[lev] = {}
    end
    append(block_handlers[lev],action)
end

--- set a keyword handler. Unlike macros, the keyword itself is always
-- passed through, but the handler may add some output afterwards.
-- If the action is nil, then the handler for that keyword is removed.
-- @param word keyword
-- @param action function to be called when keyword is encountered
-- @return previous handler associated with this keyword
function M.keyword_handler (word,action)
    if keywords[word] and keywords[word] ~= 'hook' then return end
    if action then
        keywords[word] = 'hook'
        local last = keyword_handlers[word]
        keyword_handlers[word] = action
        return last
    else
        keyword_handlers[word] = nil
        keywords[word] = nil
    end
end

-- a convenient way to use keyword handlers. This sets a handler and restores
-- the old handler at the end of the current block.
function M.make_scoped_handler(keyword,handler)
    return function()
        local last = M.keyword_handler(keyword,handler)
        M.block_handler(-1,function()
            M.keyword_handler(keyword,last)
        end)
    end
end

M.please_throw = false

function M.error(msg)
    M.please_throw = true
    msg = M.filename..':'..lexer.line..' '..msg
    if M.please_throw then
        error(msg,2)
    else
        io.stderr:write(msg,'\n')
        os.exit(1)
    end
end

M.define ('debug_',function()
    M.DEBUG = true
end)

function M.assert(expr,msg)
    if not expr then M.error(msg or 'internal error') end
end

--- Do a macro substitution on Lua source.
-- @param src Lua source (either string or file-like reader)
-- @param out output (a file-like writer)
function M.substitute(src,out,name)
    local tok = scan_lua(src,name)

    M.filename = name or '(tmp)'

    -- this function get() is always used, so that we can handle end-of-stream properly.
    -- The substitution mechanism pushes a new stream on the tstack, which is popped
    -- when empty.
    local tstack = {}
    local push,pop = table.insert,table.remove

    local function get ()
        local t,v = tok()
        while not t do
            tok = pop(tstack)
            if tok == nil then return nil end -- finally finished
            t,v = tok()
        end
        return t,v
    end

    -- this feeds the results of a substitution into the token stream.
    -- substitutions may be token lists, Lua strings or nil, in which case
    -- the substitution is ignored. The result is to push a new token stream
    -- onto the tstack, so it can be fetched using get() above
    local function push_substitution (subst)
        if subst == nil then return end
        local st = type(subst)
        push(tstack,tok)
        if st == 'table' then
            subst = scan_iter(subst)
        elseif st == 'string' then
            subst = scan_lua(subst)
        end
        tok = subst
    end
    M.push_substitution = push_substitution

    -- a macro object consists of a subst object and (optional) parameters.
    -- If there are parms, then a macro argument list must follow.
    -- The subst object is either a token list or a function; if a token list we
    -- substitute the actual parameters for the formal parameters; if a function
    -- then we call it with the actual parameters.
    -- Without parameters, it may be a simple substitution (TL or Lua string) or
    -- may be a function. In the latter case we call it passing the token getter,
    -- assuming that it will grab anything it needs from the token stream.
    local function expand_macro(get,mac)
        local pass_through
        local subst = mac.subst
        local fun = type(subst)=='function'
        if mac.parms then
            t = tnext(get);
            if t ~= '(' then
                M.error('macro '..mac.name..' expects parameters')
            end
            local args,err = M.get_list(get)
            M.assert(args,'no end of argument list')
            if fun then
                subst = subst(unpack(args))
            else
                if #mac.parms ~= #args then
                    M.error(mac.name.." takes "..#mac.parms.." arguments")
                end
                subst = substitute(subst,mac.parms,args)
            end
        elseif fun then
            subst,pass_through = subst(make_getter(get),make_putter())
        end
        push_substitution(subst)
        return pass_through
    end

    local t,v = tok()
    local last_t,last_v
    local multiline_tokens,sync = lexer.multiline_tokens,lexer.sync
    local line,last_diff = 1,0

    function M.last_token()
        return last_t,last_v
    end

    while t do
        local dump = true
        if t == 'iden' then -- classic name macro
            local mac = imacros[v]
            if mac then
                dump = expand_macro(get,mac)
            end
        elseif t == 'keyword' then
            -- important to track block level for lexical scoping and block handlers
            local class = keywords[v]
            if class == 'open' then
                if v ~= 'else' then level = level + 1 end
            elseif class == 'close' then
                level = level - 1
                if block_handlers[level] then
                    local persist
                    -- a block handler may indicate with an extra true return
                    -- that it wants to persist; the keyword is passed to them
                    -- so we can get more specific end of block handlers.
                    for _,bh in pairs(block_handlers[level]) do
                        local res,keep = bh(get,v)
                        if not keep then
                            push_substitution (res)
                        else
                            persist = persist or {}
                            append(persist,bh)
                        end
                    end
                    block_handlers[level] = persist
                end
            elseif class == 'hook' then
                local action = keyword_handlers[v]
                push_substitution(action(make_getter(get),make_putter()))
            end
        else -- any unused 'operator' token (like @, \, #) can be used as a macro
            local mac = smacros[v]
            if mac then
                dump = expand_macro(get,mac)
            end
        end
        if dump then
            out:write(v)
            if multiline_tokens[t] then
                line = sync(line, v)
                if M.filename == lexer.name then
                    local diff = line - lexer.line
                    if diff ~= last_diff then
                        --print(line,lexer.line)
                        last_diff = diff
                    end
                end
            end
        end
        last_t,last_v = t,v
        t,v = get()
    end

end

--- take some Lua source and return the result of the substitution.
-- Does not raise any errors.
-- @param src either a string or a readable file object
-- @param name optional name for the chunk
-- @return the result or nil
-- @return the error, if error
function M.substitute_tostring(src,name)
    M.please_throw = true
    local buf,k = {},1
    local out = {
        write = function(self,v)
            buf[k] = v
            k = k + 1
        end
    }
    local res,err = pcall(M.substitute,src,out,name)
    if type(src) ~= 'string' and src.close then src:close() end
    if not res then return nil,err
    else
        return table.concat(buf)
    end
end

local old_loadin = loadin
local loadin

if not old_loadin then -- Lua 5.1
    function loadin (env,src,name)
        local chunk,err = loadstring(src,name)
        if chunk and env then
            setfenv(chunk,env)
        end
        return chunk,err
    end
else -- Lua 5.2
    function loadin(env,src,name)
        local chunk,err
        if env then
            chunk,err = old_loadin(env,src,name)
        else
            chunk,err = load(src,name)
        end
        return chunk,err
    end
end

--- load Lua code in a given envrionment after passing
-- through the macro preprocessor.
-- @param env the environment (may be nil)
-- @param src either a string or a readable file object
-- @param name optional name for the chunk
-- @return the cnunk, or nil
-- @return the error, if no chunk
function M.loadin(env,src,name)
    local res,err = M.substitute_tostring(src)
    if not res then return nil,err end
    return loadin(env,res,name)
end

--- evaluate Lua macro code in a given environment.
-- @param src either a string or a readable file object
-- @param env the environment (can be nil)
-- @return true if succeeded
-- @return result(s)
function M.eval(src,env)
    local chunk,err = M.loadin(env,src,'(tmp)')
    if not chunk then return nil,err end
    return pcall(chunk)
end

function M.set_package_loader(ext)
    ext = ext or 'm.lua'
    -- directly inspired by https://github.com/bartbes/Meta/blob/master/meta.lua#L32,
    -- after a suggestion by Alexander Gladysh
    table.insert(package.loaders, function(name)
        local lname = name:gsub("%.", "/") .. '.'..ext
        local f,err = io.open(lname)
        if not f then return nil,err end
        return M.loadin(nil,f,lname)
    end)
end

return macro
