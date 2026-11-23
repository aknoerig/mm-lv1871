-- Attrappe der MoneyMoney-Laufzeitumgebung.
--
-- MoneyMoney stellt Extensions eine Reihe globaler Objekte bereit
-- (WebBanking, Connection, HTML, JSON, MM, ...). Dieses Modul installiert
-- Ersatzimplementierungen davon, sodass die Extension ohne MoneyMoney und
-- ohne Netzzugriff ausgeführt werden kann.
--
-- Dokumentation der echten Schnittstelle: https://moneymoney.app/api/webbanking/

local mock = {}

----------------------------------------------------------------------------
-- Base64 und SHA-256
--
-- Echte Implementierungen, damit sich die PKCE-Berechnung der Extension
-- tatsächlich nachrechnen lässt und nicht nur gegen sich selbst geprüft wird.
----------------------------------------------------------------------------

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function mock.base64 (data)
  local result = {}
  for index = 1, #data, 3 do
    local a, b, c = data:byte(index, index + 2)
    local buffer = a << 16 | (b or 0) << 8 | (c or 0)
    local characters = {}
    for shift = 18, 0, -6 do
      local value = buffer >> shift & 0x3f
      characters[#characters + 1] = BASE64_ALPHABET:sub(value + 1, value + 1)
    end
    if c == nil then
      characters[4] = "="
      if b == nil then
        characters[3] = "="
      end
    end
    result[#result + 1] = table.concat(characters)
  end
  return table.concat(result)
end

function mock.base64url (data)
  return (mock.base64(data):gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

local SHA256_K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local MASK32 = 0xffffffff

local function rotateRight (value, count)
  return (value >> count | value << (32 - count)) & MASK32
end

-- Liefert den SHA-256-Hash als Hex-String, genau wie MM.sha256() in MoneyMoney.
function mock.sha256 (message)
  local hash = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  }

  local bitLength = #message * 8
  local padding   = string.rep("\0", (55 - #message) % 64)
  local suffix    = {}
  for shift = 56, 0, -8 do
    suffix[#suffix + 1] = string.char(bitLength >> shift & 0xff)
  end
  message = message .. "\128" .. padding .. table.concat(suffix)

  for chunk = 1, #message, 64 do
    local w = {}
    for index = 0, 15 do
      local a, b, c, d = message:byte(chunk + index * 4, chunk + index * 4 + 3)
      w[index + 1] = (a << 24 | b << 16 | c << 8 | d) & MASK32
    end
    for index = 17, 64 do
      local s0 = rotateRight(w[index - 15], 7) ~ rotateRight(w[index - 15], 18) ~ (w[index - 15] >> 3)
      local s1 = rotateRight(w[index - 2], 17) ~ rotateRight(w[index - 2], 19) ~ (w[index - 2] >> 10)
      w[index] = (w[index - 16] + s0 + w[index - 7] + s1) & MASK32
    end

    local a, b, c, d = hash[1], hash[2], hash[3], hash[4]
    local e, f, g, h = hash[5], hash[6], hash[7], hash[8]

    for index = 1, 64 do
      local s1    = rotateRight(e, 6) ~ rotateRight(e, 11) ~ rotateRight(e, 25)
      local choice = e & f ~ ~e & MASK32 & g
      local temp1 = (h + s1 + choice + SHA256_K[index] + w[index]) & MASK32
      local s0    = rotateRight(a, 2) ~ rotateRight(a, 13) ~ rotateRight(a, 22)
      local majority = a & b ~ a & c ~ b & c
      local temp2 = (s0 + majority) & MASK32

      h, g, f = g, f, e
      e = (d + temp1) & MASK32
      d, c, b = c, b, a
      a = (temp1 + temp2) & MASK32
    end

    local updated = {a, b, c, d, e, f, g, h}
    for index = 1, 8 do
      hash[index] = (hash[index] + updated[index]) & MASK32
    end
  end

  local hex = {}
  for index = 1, 8 do
    hex[index] = string.format("%08x", hash[index])
  end
  return table.concat(hex)
end

----------------------------------------------------------------------------
-- Registrierung von Antworten
--
-- Statt echtes JSON oder HTML zu erzeugen und zu parsen, arbeiten die Tests
-- mit Markern: Der Connection-Mock gibt einen Marker-String zurück, und
-- JSON()/HTML() lösen ihn wieder zur hinterlegten Lua-Tabelle auf.
----------------------------------------------------------------------------

local payloads = {}
local pages    = {}
local counter  = 0

-- Hinterlegt eine JSON-Antwort und liefert den zugehörigen Marker.
function mock.json (value)
  counter = counter + 1
  local key = "json#" .. counter
  payloads[key] = value
  return key
end

-- Hinterlegt eine HTML-Seite und liefert den zugehörigen Marker.
--
-- Seitenmodell:
--   form     = {action = "<URL>", inputs = {"username", "password"}}
--   messages = {["<id oder CSS-Klasse>"] = "<Text>"}
function mock.page (name, model)
  pages[name] = model
  return name
end

----------------------------------------------------------------------------
-- HTML-Attrappe
--
-- Unterstützt genau die drei XPath-Formen, die die Extension verwendet:
--   //form[@id='formId'] bzw. //form
--   //input[@name='x']   bzw. .//input[@name='x' or @name='y']
--   //*[@id='x']         bzw. //*[contains(@class,'x')]
----------------------------------------------------------------------------

local function contains (list, value)
  for _, entry in ipairs(list or {}) do
    if entry == value then
      return true
    end
  end
  return false
end

local emptySelection

emptySelection = function ()
  local selection = {}
  function selection:length () return 0 end
  function selection:text () return nil end
  function selection:attr () return nil end
  function selection:xpath () return emptySelection() end
  function selection:submit () error("submit() auf leerer Auswahl aufgerufen") end
  return selection
end

local function textSelection (text)
  local selection = {}
  function selection:length () return 1 end
  function selection:text () return text end
  function selection:attr () return nil end
  return selection
end

local function inputSelection (names)
  local selection = {}
  function selection:length () return #names end
  function selection:text () return nil end
  function selection:attr (attribute, value)
    if value ~= nil then
      mock.submitted[names[1]] = value
      return selection
    end
    if attribute == "name" then
      return names[1]
    end
    return nil
  end
  return selection
end

local function formData (model)
  local parts = {}
  for _, name in ipairs(model.form.inputs) do
    parts[#parts + 1] = MM.urlencode(name) .. "=" .. MM.urlencode(mock.submitted[name] or "")
  end
  return table.concat(parts, "&")
end

local function formSelection (model, document)
  local selection = {}
  function selection:length () return 1 end
  function selection:text () return nil end
  function selection:attr (attribute) return model.form[attribute] end
  function selection:xpath (query) return document:xpath(query) end
  function selection:submit ()
    return "POST", model.form.action, formData(model), "application/x-www-form-urlencoded"
  end
  return selection
end

local function parseHTML (content)
  local model = pages[content]
  if model == nil then
    error("unbekannte HTML-Seite: " .. tostring(content))
  end

  local document = {}

  function document:xpath (query)
    if query:find("input", 1, true) then
      local present = {}
      for name in query:gmatch("@name='([^']*)'") do
        if model.form and contains(model.form.inputs, name) then
          present[#present + 1] = name
        end
      end
      if #present == 0 then
        return emptySelection()
      end
      return inputSelection(present)
    end

    if query:find("form", 1, true) then
      if model.form == nil then
        return emptySelection()
      end
      return formSelection(model, document)
    end

    local key = query:match("@id='([^']*)'") or query:match("contains%(@class,'([^']*)'%)")
    local text = key and model.messages and model.messages[key]
    if text then
      return textSelection(text)
    end
    return emptySelection()
  end

  return document
end

----------------------------------------------------------------------------
-- Installation der globalen Objekte
----------------------------------------------------------------------------

-- Setzt den aufgezeichneten Zustand zurück (Formularwerte, Request-Log).
function mock.reset ()
  mock.submitted = {}
  mock.requests  = {}
  mock.messages  = {}
  mock.lastURL   = ""
  mock.closed    = false
  mock.definition = nil
end

-- Installiert die globalen MoneyMoney-Objekte. "handler" beantwortet
-- HTTP-Anfragen und liefert "content" sowie optional die URL, auf der die
-- Anfrage nach Weiterleitungen gelandet ist.
function mock.install (handler)
  mock.reset()

  local randomState = 0x2545f491

  ProtocolWebBanking = "ProtocolWebBanking"
  ProtocolFinTS      = "ProtocolFinTS"
  LoginFailed        = "LoginFailed"

  WebBanking = function (definition)
    mock.definition = definition
  end

  JSON = function (content)
    return {
      dictionary = function ()
        local value = payloads[content]
        if value == nil then
          error("kein JSON hinterlegt für: " .. tostring(content))
        end
        return value
      end
    }
  end

  HTML = parseHTML

  MM = {
    urlencode = function (text)
      return (tostring(text):gsub("[^%w%-%._~]", function (character)
        return string.format("%%%02X", character:byte())
      end))
    end,
    base64      = mock.base64,
    sha256      = mock.sha256,
    printStatus = function (...)
      mock.messages[#mock.messages + 1] = table.concat({...}, " ")
    end,
    random = function (length)
      local bytes = {}
      for index = 1, length do
        randomState = (randomState * 1103515245 + 12345) & MASK32
        bytes[index] = string.char(randomState >> 16 & 0xff)
      end
      return table.concat(bytes)
    end
  }

  Connection = function ()
    local connection = {}

    function connection:request (method, url, body, contentType, headers)
      mock.requests[#mock.requests + 1] = {
        method = method, url = url, body = body, headers = headers
      }
      mock.lastURL = url
      local content, finalURL, responseHeaders = handler(method, url, body, headers)
      if finalURL then
        mock.lastURL = finalURL
      end
      return content, "utf-8", "text/html", nil, responseHeaders
    end

    function connection:getBaseURL ()
      return mock.lastURL
    end

    function connection:close ()
      mock.closed = true
    end

    return connection
  end
end

-- Liefert die zuletzt aufgezeichnete Anfrage, deren URL "pattern" enthält.
function mock.lastRequest (pattern)
  for index = #mock.requests, 1, -1 do
    if mock.requests[index].url:find(pattern, 1, true) then
      return mock.requests[index]
    end
  end
  return nil
end

-- Zählt die aufgezeichneten Anfragen, deren Body "pattern" enthält.
function mock.countRequests (pattern)
  local count = 0
  for _, request in ipairs(mock.requests) do
    if request.body and request.body:find(pattern, 1, true) then
      count = count + 1
    end
  end
  return count
end

return mock
