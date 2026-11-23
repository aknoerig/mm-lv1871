-- Inoffizielle MoneyMoney-Extension für das Kundenportal "Meine LV 1871"
-- der Lebensversicherung von 1871 a. G. München.
--
-- Legt für jeden Vertrag ein Konto an:
--   * fondsgebundene Verträge als Depot mit der aktuellen Vermögensaufteilung
--     (Fonds mit ISIN, Deckungskapital, Schlussüberschuss)
--   * alle übrigen Verträge als Konto mit dem Vertragsguthaben als Saldo
--
-- Benutzername: Kundennummer für "Meine LV 1871"
-- Passwort:     zugehöriges Passwort
--               Ist eine Authenticator-App hinterlegt, fragt MoneyMoney
--               anschließend nach dem sechsstelligen Einmalcode.
--
-- Die Anmeldung läuft exakt über dieselben Schritte wie das Portal im Browser
-- (OpenID Connect Authorization Code Flow mit PKCE), damit auch alle
-- zusätzlichen Anmeldeschritte der LV 1871 durchlaufen werden.
--
-- MIT License
--
-- Copyright (c) 2026 André Knörig
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

WebBanking{
  version     = 1.02,
  country     = "de",
  url         = "https://serviceonline.lv1871.de/",
  services    = {"LV 1871"},
  description = "Verträge aus dem Kundenportal Meine LV 1871 abrufen (Vertragsguthaben, Fondsaufteilung, Rückkaufswert)"
}

local authURL     = "https://auth.lv1871.de/auth/realms/lv1871-customer/protocol/openid-connect"
local apiURL      = "https://serviceonline-gateway.lv1871.de/middleware"
local redirectURL = "https://serviceonline.lv1871.de/meineLV/uebersicht"
local clientId    = "lv1871-kundenportal-ui"
local currency    = "EUR"

local connection
local codeVerifier
local pendingPage           -- HTML der offenen Anmeldeseite (z. B. Einmalcode)
local pendingField          -- Name des Eingabefelds auf dieser Seite
local accessToken
local refreshToken
local tokenExpires = 0
local contracts             -- versicherungsnummer (String) -> Vertragscontainer

----------------------------------------------------------------------------
-- Hilfsfunktionen
----------------------------------------------------------------------------

local function encodeParameters (params)
  local parts = {}
  for key, value in pairs(params) do
    parts[#parts + 1] = MM.urlencode(key) .. "=" .. MM.urlencode(tostring(value))
  end
  return table.concat(parts, "&")
end

local function parseJSON (content)
  if content == nil or content == "" then
    return nil
  end
  local success, value = pcall(function ()
    return JSON(content):dictionary()
  end)
  if success and type(value) == "table" then
    return value
  end
  return nil
end

-- Liefert den ersten nicht-leeren String aus der Argumentliste.
local function firstText (...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if type(value) == "string" and value ~= "" then
      return value
    end
  end
  return nil
end

local function trim (text)
  if text == nil then
    return nil
  end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

----------------------------------------------------------------------------
-- PKCE
----------------------------------------------------------------------------

local function base64url (data)
  local encoded = MM.base64(data)
  encoded = encoded:gsub("%+", "-")
  encoded = encoded:gsub("/", "_")
  encoded = encoded:gsub("=", "")
  return encoded
end

local function hexToBinary (hex)
  return (hex:gsub("%x%x", function (byte)
    return string.char(tonumber(byte, 16))
  end))
end

local function createCodeChallenge (verifier)
  return base64url(hexToBinary(MM.sha256(verifier)))
end

----------------------------------------------------------------------------
-- Anmeldung (OpenID Connect Authorization Code Flow mit PKCE)
----------------------------------------------------------------------------

-- Fordert ein Token an. Liefert true oder nil plus Fehlerbeschreibung.
local function requestToken (params)
  params.client_id = clientId

  local content
  local success = pcall(function ()
    content = connection:request("POST", authURL .. "/token",
                                 encodeParameters(params),
                                 "application/x-www-form-urlencoded",
                                 {["Accept"] = "application/json"})
  end)
  if not success then
    return nil, "Der Anmeldeserver der LV 1871 ist nicht erreichbar."
  end

  local response = parseJSON(content)
  if response == nil then
    return nil, "Unerwartete Antwort des Anmeldeservers."
  end

  if response.access_token then
    accessToken  = response.access_token
    refreshToken = response.refresh_token
    tokenExpires = os.time() + (tonumber(response.expires_in) or 300)
    return true
  end

  return nil, response.error_description or response.error
end

local function renewAccessToken ()
  if refreshToken == nil then
    return false
  end
  return requestToken{grant_type = "refresh_token", refresh_token = refreshToken} == true
end

-- Sucht den Autorisierungscode in der zuletzt aufgerufenen URL bzw. in einer
-- Weiterleitung, der MoneyMoney nicht gefolgt ist.
local function authorizationCode (headers)
  local lastURL = connection:getBaseURL()
  if type(lastURL) == "string" then
    local code = lastURL:match("[?&]code=([^&#]+)")
    if code then
      return code
    end
  end
  if type(headers) == "table" then
    for key, value in pairs(headers) do
      if type(value) == "string" and string.lower(key) == "location" then
        local code = value:match("[?&]code=([^&#]+)")
        if code then
          return code
        end
      end
    end
  end
  return nil
end

-- Meldung der Anmeldeseite (z. B. "Ungültige Anmeldedaten").
local function pageMessage (html)
  for _, query in ipairs({"//*[@id='lvMessageTextId']",
                          "//*[contains(@class,'lv-message-text')]",
                          "//*[contains(@class,'kc-feedback-text')]"}) do
    local elements = html:xpath(query)
    if elements:length() > 0 then
      local text = trim(elements:text())
      if text and text ~= "" then
        return text
      end
    end
  end
  return nil
end

local function loginForm (html)
  local form = html:xpath("//form[@id='formId']")
  if form:length() == 0 then
    form = html:xpath("//form")
  end
  if form:length() == 0 then
    return nil
  end
  return form
end

-- Wertet die Antwort eines Anmeldeschritts aus: entweder liegt der
-- Autorisierungscode vor, oder die LV 1871 verlangt eine weitere Eingabe.
local function handleLoginResponse (content, headers, step)
  local code = authorizationCode(headers)
  if code then
    pendingPage, pendingField = nil, nil
    local success, message = requestToken{
      grant_type    = "authorization_code",
      code          = code,
      redirect_uri  = redirectURL,
      code_verifier = codeVerifier
    }
    if success then
      return nil
    end
    return "Anmeldung bei Meine LV 1871 fehlgeschlagen: " ..
           (message or "Der Zugriffstoken konnte nicht abgerufen werden.")
  end

  if content == nil or content == "" then
    return "Unerwartete Antwort des Anmeldeservers der LV 1871."
  end

  local html = HTML(content)

  -- Weiterer Anmeldeschritt mit Einmalcode?
  local otpInput = html:xpath("//input[@name='otp' or @name='totp']")
  if otpInput:length() > 0 then
    if step == 1 then
      pendingPage  = content
      pendingField = otpInput:attr("name")
      return {
        title     = "Zwei-Faktor-Authentifizierung",
        challenge = firstText(pageMessage(html)) or
                    "Bitte geben Sie den sechsstelligen Code aus Ihrer Authenticator-App ein.",
        label     = "Einmalcode"
      }
    end

    -- Die LV 1871 zeigt die Seite erneut: der Einmalcode wurde abgelehnt.
    pendingPage, pendingField = nil, nil
    local message = pageMessage(html)
    if message then
      return "Anmeldung bei Meine LV 1871 fehlgeschlagen: " .. message
    end
    return LoginFailed
  end

  pendingPage, pendingField = nil, nil

  -- Verlangt die LV 1871 ein neues Passwort, muss das im Browser erledigt werden.
  if html:xpath("//input[@name='password-new']"):length() > 0 then
    return "Die LV 1871 verlangt die Vergabe eines neuen Passworts. " ..
           "Bitte melden Sie sich einmal unter serviceonline.lv1871.de an."
  end

  local message = pageMessage(html)
  if message then
    return "Anmeldung bei Meine LV 1871 fehlgeschlagen: " .. message
  end

  if html:xpath("//input[@name='password']"):length() > 0 then
    return LoginFailed
  end

  return "Die Anmeldung bei Meine LV 1871 konnte nicht abgeschlossen werden."
end

local function submitForm (form)
  local method, url, postContent, postContentType = form:submit()
  local content, charset, mimeType, filename, headers =
      connection:request(method, url, postContent, postContentType)
  return content, headers
end

----------------------------------------------------------------------------
-- Zugriff auf die Vertragsauskunft
----------------------------------------------------------------------------

local function apiRequest (path, params, isRetry)
  if accessToken == nil then
    error("Keine gültige Anmeldung bei der LV 1871.")
  end

  -- Das Zugriffstoken ist nur wenige Minuten gültig.
  if os.time() >= tokenExpires - 30 then
    renewAccessToken()
  end

  local url = apiURL .. path
  if params then
    local query = encodeParameters(params)
    if query ~= "" then
      url = url .. "?" .. query
    end
  end

  local content = connection:request("GET", url, nil, nil, {
    ["Accept"]        = "application/json",
    ["Authorization"] = "Bearer " .. accessToken
  })

  -- Für Verträge ohne den jeweiligen Datenbestand antwortet die Schnittstelle
  -- mit "NOT_FOUND" statt mit einem JSON-Objekt.
  if content and string.find(content, "NOT_FOUND", 1, true) then
    return nil
  end

  local response = parseJSON(content)
  if response == nil and not isRetry and renewAccessToken() then
    return apiRequest(path, params, true)
  end

  return response
end

local function loadContracts ()
  if contracts then
    return contracts
  end

  MM.printStatus("Lade Vertragsübersicht der LV 1871.")

  local response = apiRequest("/vertragsauskunft")
  local data     = response and (response.data or response)
  if data == nil or data.vertraege == nil then
    error("Die Vertragsauskunft der LV 1871 konnte nicht gelesen werden.")
  end

  contracts = {}
  for _, container in ipairs(data.vertraege) do
    local vertrag = container.vertrag
    if vertrag and vertrag.versicherungsnummer then
      contracts[tostring(vertrag.versicherungsnummer)] = container
    end
  end

  return contracts
end

----------------------------------------------------------------------------
-- Vertragsdaten aufbereiten
----------------------------------------------------------------------------

local function contractName (container)
  local vertrag = container.vertrag or {}
  local produkt = container.produkt or {}
  local tarif   = vertrag.tarif or {}
  return firstText(produkt.bezeichnungLang, produkt.bezeichnungKurz,
                   tarif.bezeichnungLang, tarif.kurzbezeichnung)
      or ("Vertrag " .. tostring(vertrag.versicherungsnummer))
end

local function contractOwner (container)
  local rollen = container.rollen
  if rollen and rollen.versicherungsnehmer then
    for _, rolle in ipairs(rollen.versicherungsnehmer) do
      local person = rolle.person
      if person then
        local name = firstText(person.nachname)
        if name then
          local vorname = firstText(person.vorname)
          if vorname then
            return vorname .. " " .. name
          end
          return name
        end
      end
    end
  end
  return nil
end

local function isFundLinked (container)
  local vertrag = container.vertrag or {}
  local art     = vertrag.art or {}
  return art.vertragstyp == "FONDS"
end

-- Nur laufende Verträge sind für die Vermögensübersicht interessant.
local function isCurrent (container)
  local vertrag = container.vertrag or {}
  local status  = vertrag.status
  if status == nil or status.art == nil then
    return true
  end
  return status.art == "AKTIV" or status.art == "AUFSCHUB"
end

-- Aktuelle Vermögenswerte eines Vertrags (Guthaben, Fondsaufteilung).
local function currentAssets (insuranceNumber)
  local response = apiRequest("/vertragsauskunft/vermoegenswerte", {
    versicherungsnummer = insuranceNumber,
    latest              = "true"
  })
  if type(response) == "table" and response[1] then
    return response[1]
  end
  return nil
end

local function calculatedValues (insuranceNumber)
  return apiRequest("/vertragsauskunft/kalkuliertewerte", {
    versicherungsnummer = insuranceNumber
  })
end

-- Hängt die Fonds eines Vermögensblocks an die Wertpapierliste an.
local function appendFunds (securities, funds)
  if funds == nil then
    return 0
  end
  if funds.fondsname or funds.isin then
    funds = {funds}
  end

  local total = 0
  for _, fund in ipairs(funds) do
    local amount = tonumber(fund.wert)
    if amount then
      securities[#securities + 1] = {
        name   = firstText(fund.fondsname, fund.isin) or "Fonds",
        isin   = firstText(fund.isin),
        amount = amount
      }
      total = total + amount
    end
  end
  return total
end

----------------------------------------------------------------------------
-- MoneyMoney-Schnittstelle
----------------------------------------------------------------------------

function SupportsBank (protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "LV 1871"
end

function InitializeSession2 (protocol, bankCode, step, credentials, interactive)
  if step == 1 then
    connection = Connection()
    connection.language = "de-de"

    MM.printStatus("Rufe Anmeldeseite von Meine LV 1871 auf.")

    codeVerifier = base64url(MM.random(32))
    local authRequestURL = authURL .. "/auth?" .. encodeParameters{
      client_id             = clientId,
      redirect_uri          = redirectURL,
      response_type         = "code",
      response_mode         = "query",
      scope                 = "openid",
      state                 = base64url(MM.random(12)),
      nonce                 = base64url(MM.random(12)),
      code_challenge        = createCodeChallenge(codeVerifier),
      code_challenge_method = "S256"
    }

    local content = connection:request("GET", authRequestURL)
    local form    = loginForm(HTML(content))
    if form == nil then
      return "Die Anmeldeseite der LV 1871 konnte nicht gelesen werden."
    end

    form:xpath(".//input[@name='username']"):attr("value", credentials[1])
    form:xpath(".//input[@name='password']"):attr("value", credentials[2])

    MM.printStatus("Melde bei Meine LV 1871 an.")
    local content, headers = submitForm(form)
    return handleLoginResponse(content, headers, 1)
  end

  if pendingPage == nil then
    return LoginFailed
  end

  local form = loginForm(HTML(pendingPage))
  if form == nil then
    return "Die Seite für den Einmalcode konnte nicht gelesen werden."
  end
  form:xpath(".//input[@name='" .. pendingField .. "']"):attr("value", credentials[1])

  MM.printStatus("Prüfe Einmalcode.")
  local content, headers = submitForm(form)
  return handleLoginResponse(content, headers, 2)
end

function ListAccounts (knownAccounts)
  local accounts = {}

  for insuranceNumber, container in pairs(loadContracts()) do
    if isCurrent(container) then
      local portfolio = isFundLinked(container)
      accounts[#accounts + 1] = {
        name          = contractName(container),
        owner         = contractOwner(container),
        accountNumber = insuranceNumber,
        bankCode      = "LV 1871",
        currency      = currency,
        portfolio     = portfolio,
        type          = portfolio and "AccountTypePortfolio" or "AccountTypeSavings"
      }
    end
  end

  if #accounts == 0 then
    return "Im Kundenportal Meine LV 1871 wurden keine laufenden Verträge gefunden."
  end

  table.sort(accounts, function (a, b) return a.accountNumber < b.accountNumber end)
  return accounts
end

function RefreshAccount (account, since)
  local insuranceNumber = account.accountNumber
  local container       = loadContracts()[insuranceNumber]

  MM.printStatus("Rufe Vertrag " .. insuranceNumber .. " ab.")

  local assets = currentAssets(insuranceNumber)

  if account.portfolio then
    local securities = {}
    local total      = 0

    if assets then
      if tonumber(assets.summeDeckungskapital) then
        total = total + tonumber(assets.summeDeckungskapital)
        securities[#securities + 1] = {
          name   = "Deckungskapital",
          amount = tonumber(assets.summeDeckungskapital)
        }
      end
      total = total + appendFunds(securities, assets.garantieFonds)
      total = total + appendFunds(securities, assets.freieFondsAktuellBespart)
      total = total + appendFunds(securities, assets.freieFondsRuhend)
      if tonumber(assets.schlussUeberschussInklusiveBewertungsreserve) then
        total = total + tonumber(assets.schlussUeberschussInklusiveBewertungsreserve)
        securities[#securities + 1] = {
          name   = "Schlussüberschuss inkl. Bewertungsreserve",
          amount = tonumber(assets.schlussUeberschussInklusiveBewertungsreserve)
        }
      end
    end

    -- Liegt keine Aufteilung vor, wird das Vertragsguthaben als einzelne
    -- Position ausgewiesen, damit der Saldo trotzdem stimmt.
    local balance = assets and tonumber(assets.vertragsguthaben)
    if #securities == 0 then
      if balance == nil then
        error("Für den Vertrag " .. insuranceNumber ..
              " liefert die LV 1871 derzeit keine Vermögenswerte.")
      end
      securities[#securities + 1] = {
        name   = container and contractName(container) or "Vertragsguthaben",
        amount = balance
      }
    elseif balance and math.abs(balance - total) >= 0.01 then
      -- Differenz zwischen Guthaben und aufgeschlüsselten Werten ausgleichen.
      securities[#securities + 1] = {
        name   = "Weitere Vertragswerte",
        amount = balance - total
      }
    end

    return {securities = securities}
  end

  local balance = assets and tonumber(assets.vertragsguthaben)

  if balance == nil then
    -- Klassische Verträge ohne Guthabenausweis: ersatzweise den Rückkaufswert
    -- verwenden.
    local values = calculatedValues(insuranceNumber)
    if values and values.rueckkauf then
      balance = tonumber(values.rueckkauf.betragInklusiveSteuerabzug)
    end
  end

  if balance == nil then
    error("Für den Vertrag " .. insuranceNumber ..
          " liefert die LV 1871 derzeit keinen Wert.")
  end

  return {balance = balance, transactions = {}}
end

function EndSession ()
  if connection then
    if refreshToken then
      pcall(function ()
        connection:request("POST", authURL .. "/logout",
                           encodeParameters{client_id = clientId,
                                            refresh_token = refreshToken},
                           "application/x-www-form-urlencoded",
                           {["Accept"] = "application/json"})
      end)
    end
    connection:close()
  end

  accessToken  = nil
  refreshToken = nil
  codeVerifier = nil
  pendingPage  = nil
  pendingField = nil
  contracts    = nil
end
