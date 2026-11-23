-- Testsuite der MoneyMoney-Extension "LV 1871".
--
-- Aufruf aus dem Projektverzeichnis:  lua test/run.lua
--
-- Die Tests laden "LV 1871.lua" in eine nachgebaute MoneyMoney-Umgebung
-- (siehe test/moneymoney.lua) und beantworten deren HTTP-Anfragen mit
-- simulierten Portalantworten (siehe test/fixtures.lua). Es geht keine
-- Anfrage ins Netz, und es werden keine echten Zugangsdaten benötigt.

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local mock     = require("moneymoney")
local fixtures = require("fixtures")

local EXTENSION = here .. "/../LV 1871.lua"
local SERVICE   = "LV 1871"

----------------------------------------------------------------------------
-- Hilfsmittel
----------------------------------------------------------------------------

local tests = {}

local function test (name, run)
  tests[#tests + 1] = {name = name, run = run}
end

-- Setzt Mock und Szenario zurück und lädt die Extension neu, damit jeder
-- Test mit frischem Zustand (ohne Token, ohne Vertragscache) startet.
local function loadExtension ()
  local scenario = fixtures.reset()
  dofile(EXTENSION)
  return scenario
end

local function assertEquals (actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: erwartet %s, erhalten %s",
                        label or "Wert", tostring(expected), tostring(actual)), 2)
  end
end

local function assertClose (actual, expected, label)
  if type(actual) ~= "number" or math.abs(actual - expected) >= 0.005 then
    error(string.format("%s: erwartet %.2f, erhalten %s",
                        label or "Betrag", expected, tostring(actual)), 2)
  end
end

local function assertContains (text, needle, label)
  if type(text) ~= "string" or not text:find(needle, 1, true) then
    error(string.format("%s: %q enthält nicht %q",
                        label or "Text", tostring(text), needle), 2)
  end
end

local function login (credentials)
  return InitializeSession2(ProtocolWebBanking, SERVICE, 1,
                            credentials or {"4711", "geheim"}, true)
end

local function loginOK ()
  local result = login()
  assertEquals(result, nil, "Anmeldung")
end

local function accountByNumber (accounts, number)
  for _, account in ipairs(accounts) do
    if account.accountNumber == number then
      return account
    end
  end
  error("Konto " .. number .. " nicht in der Kontenliste", 2)
end

local function securityByName (securities, name)
  for _, security in ipairs(securities) do
    if security.name == name then
      return security
    end
  end
  error("Position " .. name .. " nicht im Depot", 2)
end

local function hexToBinary (hex)
  return (hex:gsub("%x%x", function (byte)
    return string.char(tonumber(byte, 16))
  end))
end

local function expectError (callback)
  local ok, message = pcall(callback)
  if ok then
    error("Fehler erwartet, aber der Aufruf war erfolgreich", 2)
  end
  return tostring(message)
end

----------------------------------------------------------------------------
-- Deklaration
----------------------------------------------------------------------------

test("Extension meldet sich als Dienst \"LV 1871\" an", function ()
  loadExtension()
  assertEquals(mock.definition.services[1], SERVICE, "Dienstname")
  assertEquals(mock.definition.country, "de", "Land")
  assert(type(mock.definition.description) == "string" and #mock.definition.description > 0,
         "Beschreibung fehlt")
  assert(mock.definition.version >= 1.0, "Version fehlt")
end)

test("SupportsBank akzeptiert nur den eigenen Dienst", function ()
  loadExtension()
  assert(SupportsBank(ProtocolWebBanking, SERVICE), "eigener Dienst wird abgelehnt")
  assert(not SupportsBank(ProtocolWebBanking, "Sparkasse"), "fremde Bank wird akzeptiert")
  assert(not SupportsBank(ProtocolFinTS, SERVICE), "falsches Protokoll wird akzeptiert")
end)

----------------------------------------------------------------------------
-- Anmeldung
----------------------------------------------------------------------------

test("Anmeldung füllt das Keycloak-Formular des Portals", function ()
  loadExtension()
  loginOK()
  assertEquals(mock.submitted.username, "4711", "Kundennummer")
  assertEquals(mock.submitted.password, "geheim", "Passwort")

  local request = mock.lastRequest("login-actions/authenticate")
  assert(request, "Anmeldeformular wurde nicht abgeschickt")
  assertEquals(request.method, "POST", "HTTP-Methode")
  assertContains(request.body, "username=4711", "Formulardaten")
end)

test("Autorisierungscode wird gegen ein Zugriffstoken getauscht", function ()
  loadExtension()
  loginOK()
  local request = mock.lastRequest("openid-connect/token")
  assert(request, "Token-Request fehlt")
  assertContains(request.body, "grant_type=authorization_code", "Token-Request")
  assertContains(request.body, "client_id=lv1871-kundenportal-ui", "Token-Request")
  assertContains(request.body, fixtures.code, "Token-Request")
end)

test("PKCE: Code-Challenge passt zum übermittelten Verifier", function ()
  loadExtension()
  loginOK()

  local authRequest  = mock.lastRequest("openid-connect/auth?")
  local tokenRequest = mock.lastRequest("openid-connect/token")

  local challenge = authRequest.url:match("code_challenge=([^&]+)")
  local method    = authRequest.url:match("code_challenge_method=([^&]+)")
  local verifier   = tokenRequest.body:match("code_verifier=([^&]+)")

  assertEquals(method, "S256", "Challenge-Verfahren")
  assert(verifier and #verifier >= 43, "Verifier ist zu kurz für RFC 7636")
  assertEquals(mock.base64url(hexToBinary(mock.sha256(verifier))), challenge,
               "Code-Challenge")
  assertContains(authRequest.url, "response_type=code", "Autorisierungsanfrage")
  assertContains(authRequest.url, "client_id=lv1871-kundenportal-ui", "Autorisierungsanfrage")
end)

test("Testumgebung rechnet SHA-256 korrekt (RFC-7636-Beispiel)", function ()
  -- Prüft die Hilfsfunktionen der Testumgebung selbst, damit der
  -- PKCE-Test oben nicht nur gegen sich selbst vergleicht.
  local verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  assertEquals(mock.sha256(verifier),
               "13d31e961a1ad8ec2f16b10c4c982e0876a878ad6df144566ee1894acb70f9c3",
               "SHA-256")
  assertEquals(mock.base64url(hexToBinary(mock.sha256(verifier))),
               "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "Code-Challenge")
  assertEquals(mock.sha256(""),
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
               "SHA-256 der leeren Zeichenkette")
  assertEquals(mock.sha256(string.rep("a", 64)),
               "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
               "SHA-256 über zwei Blöcke")
end)

test("Falsche Zugangsdaten werden mit der Meldung des Portals gemeldet", function ()
  local scenario = loadExtension()
  scenario.loginOutcome = "wrongCredentials"
  local result = login({"4711", "falsch"})
  assertContains(result, "Ungültige Anmeldedaten", "Fehlermeldung")
end)

test("Vorübergehend gesperrter Zugang wird gemeldet", function ()
  local scenario = loadExtension()
  scenario.loginOutcome = "locked"
  local result = login()
  assertContains(result, "vorübergehend gesperrt", "Fehlermeldung")
end)

test("Anmeldeseite ohne Meldung führt zu LoginFailed", function ()
  local scenario = loadExtension()
  scenario.loginOutcome = "silentFailure"
  assertEquals(login(), LoginFailed, "Rückgabewert")
end)

test("Abgelehnter Token-Tausch wird gemeldet", function ()
  local scenario = loadExtension()
  scenario.tokenOutcome = "denied"
  local result = login()
  assertContains(result, "Code not valid", "Fehlermeldung")
end)

test("Erzwungene Passwortänderung wird erkannt", function ()
  local scenario = loadExtension()
  scenario.loginOutcome = "passwordUpdate"
  local result = login()
  assertContains(result, "neuen Passworts", "Hinweis")
  assertContains(result, "serviceonline.lv1871.de", "Hinweis")
end)

----------------------------------------------------------------------------
-- Zwei-Faktor-Authentifizierung
----------------------------------------------------------------------------

test("Zwei-Faktor: erste Stufe fragt den Einmalcode ab", function ()
  local scenario = loadExtension()
  scenario.loginOutcome = "otp"
  local challenge = login()
  assertEquals(type(challenge), "table", "Rückgabetyp")
  assert(#challenge.title > 0, "Titel fehlt")
  assert(#challenge.challenge > 0, "Fragetext fehlt")
  assertEquals(challenge.label, "Einmalcode", "Feldbezeichnung")
end)

test("Zwei-Faktor: zweite Stufe schließt die Anmeldung ab", function ()
  local scenario = loadExtension()
  scenario.loginOutcome = "otp"
  assertEquals(type(login()), "table", "erste Stufe")

  local result = InitializeSession2(ProtocolWebBanking, SERVICE, 2, {"123456"}, true)
  assertEquals(result, nil, "zweite Stufe")
  assertEquals(mock.submitted.otp, "123456", "Einmalcode")
  assertContains(mock.lastRequest("openid-connect/token").body,
                 "grant_type=authorization_code", "Token-Request")
end)

test("Zwei-Faktor: falscher Einmalcode wird gemeldet statt erneut abgefragt", function ()
  local scenario = loadExtension()
  scenario.loginOutcome = "otp"
  login()
  scenario.otpOutcome = "wrongCode"

  local result = InitializeSession2(ProtocolWebBanking, SERVICE, 2, {"000000"}, true)
  assertEquals(type(result), "string", "Rückgabetyp")
  assertContains(result, "Ungültiger Einmalcode", "Fehlermeldung")
end)

test("Zweite Stufe ohne vorangehende Abfrage schlägt fehl", function ()
  loadExtension()
  assertEquals(InitializeSession2(ProtocolWebBanking, SERVICE, 2, {"123456"}, true),
               LoginFailed, "Rückgabewert")
end)

----------------------------------------------------------------------------
-- Kontenliste
----------------------------------------------------------------------------

test("ListAccounts liefert nur laufende Verträge", function ()
  loadExtension()
  loginOK()
  local accounts = ListAccounts({})
  assertEquals(type(accounts), "table", "Rückgabetyp")
  assertEquals(#accounts, 2, "Anzahl der Konten")
  accountByNumber(accounts, "12345678")
  accountByNumber(accounts, "87654321")
  for _, account in ipairs(accounts) do
    assert(account.accountNumber ~= "11112222", "beendeter Vertrag wird angelegt")
    assertEquals(account.currency, "EUR", "Währung")
  end
end)

test("Fondsgebundener Vertrag wird ein Depot", function ()
  loadExtension()
  loginOK()
  local account = accountByNumber(ListAccounts({}), "12345678")
  assertEquals(account.portfolio, true, "Depot-Kennzeichen")
  assertEquals(account.type, "AccountTypePortfolio", "Kontotyp")
  assertEquals(account.name, "MeinPlan Rente Invest", "Kontoname")
  assertEquals(account.owner, "Erika Mustermann", "Inhaber")
end)

test("Klassischer Vertrag wird ein Konto, Name fällt auf den Tarif zurück", function ()
  loadExtension()
  loginOK()
  local account = accountByNumber(ListAccounts({}), "87654321")
  assertEquals(account.portfolio, false, "Depot-Kennzeichen")
  assertEquals(account.type, "AccountTypeSavings", "Kontotyp")
  assertEquals(account.name, "RV12", "Kontoname")
  assertEquals(account.owner, nil, "Inhaber")
end)

test("Leere Vertragsliste wird als Meldung zurückgegeben", function ()
  local scenario = loadExtension()
  loginOK()
  scenario.contracts = {data = {vertraege = {}}}
  assertContains(ListAccounts({}), "keine laufenden Verträge", "Meldung")
end)

----------------------------------------------------------------------------
-- Depot
----------------------------------------------------------------------------

test("Depot: Positionen ergeben zusammen das Vertragsguthaben", function ()
  loadExtension()
  loginOK()
  local account = accountByNumber(ListAccounts({}), "12345678")
  local result  = RefreshAccount(account, nil)

  assertEquals(type(result.securities), "table", "Wertpapierliste")
  assertEquals(#result.securities, 5, "Anzahl der Positionen")

  local total = 0
  for _, security in ipairs(result.securities) do
    total = total + security.amount
  end
  assertClose(total, 48250.75, "Summe der Positionen")

  assertClose(securityByName(result.securities, "Deckungskapital").amount, 12000.00)
  assertEquals(securityByName(result.securities, "MSCI World ETF").isin, "IE00B4L5Y983", "ISIN")
  assertClose(securityByName(result.securities, "LV 1871 Garantiefonds").amount, 8000.50)
  assertClose(securityByName(result.securities,
              "Schlussüberschuss inkl. Bewertungsreserve").amount, 2250.00)
end)

test("Depot: Differenz zum Guthaben wird ausgeglichen", function ()
  local scenario = loadExtension()
  loginOK()
  scenario.assets["12345678"][1].vertragsguthaben = 50000.00

  local account = accountByNumber(ListAccounts({}), "12345678")
  local result  = RefreshAccount(account, nil)

  assertClose(securityByName(result.securities, "Weitere Vertragswerte").amount, 1749.25)
  local total = 0
  for _, security in ipairs(result.securities) do
    total = total + security.amount
  end
  assertClose(total, 50000.00, "Summe der Positionen")
end)

test("Depot ohne Aufteilung: eine Position mit dem Vertragsguthaben", function ()
  local scenario = loadExtension()
  loginOK()
  scenario.assets["12345678"] = {{wirksamkeitsdatum = "2026-11-01",
                                  vertragsguthaben  = 1234.56}}

  local account = accountByNumber(ListAccounts({}), "12345678")
  local result  = RefreshAccount(account, nil)

  assertEquals(#result.securities, 1, "Anzahl der Positionen")
  assertEquals(result.securities[1].name, "MeinPlan Rente Invest", "Bezeichnung")
  assertClose(result.securities[1].amount, 1234.56)
end)

test("Depot ohne Vermögenswerte: klare Fehlermeldung", function ()
  local scenario = loadExtension()
  loginOK()
  local account = accountByNumber(ListAccounts({}), "12345678")
  scenario.assets["12345678"] = nil

  assertContains(expectError(function () return RefreshAccount(account, nil) end),
                 "keine Vermögenswerte", "Fehlermeldung")
end)

----------------------------------------------------------------------------
-- Konto
----------------------------------------------------------------------------

test("Konto: Vertragsguthaben wird als Saldo verwendet", function ()
  local scenario = loadExtension()
  loginOK()
  scenario.assets["87654321"] = {{wirksamkeitsdatum = "2026-11-01",
                                  vertragsguthaben  = 19980.13}}

  local account = accountByNumber(ListAccounts({}), "87654321")
  local result  = RefreshAccount(account, nil)

  assertClose(result.balance, 19980.13, "Saldo")
  assertEquals(type(result.transactions), "table", "Umsatzliste")
  assertEquals(#result.transactions, 0, "Anzahl der Umsätze")
end)

test("Konto: ohne Guthabenausweis dient der Rückkaufswert als Saldo", function ()
  loadExtension()
  loginOK()
  local account = accountByNumber(ListAccounts({}), "87654321")
  local result  = RefreshAccount(account, nil)
  assertClose(result.balance, 15750.42, "Saldo")
end)

test("Konto ohne jeden Wert: klare Fehlermeldung", function ()
  local scenario = loadExtension()
  loginOK()
  local account = accountByNumber(ListAccounts({}), "87654321")
  scenario.calculated["87654321"] = nil

  assertContains(expectError(function () return RefreshAccount(account, nil) end),
                 "keinen Wert", "Fehlermeldung")
end)

----------------------------------------------------------------------------
-- Sitzung
----------------------------------------------------------------------------

test("Abgelaufenes Zugriffstoken wird vor dem Abruf erneuert", function ()
  local scenario = loadExtension()
  scenario.tokenLifetime = 0
  loginOK()
  assertEquals(mock.countRequests("grant_type=refresh_token"), 0, "Erneuerungen vor dem Abruf")

  ListAccounts({})
  assert(mock.countRequests("grant_type=refresh_token") >= 1,
         "Token wurde nicht erneuert")
end)

test("EndSession meldet ab und schließt die Verbindung", function ()
  loadExtension()
  loginOK()
  EndSession()

  local request = mock.lastRequest("openid-connect/logout")
  assert(request, "Abmeldung fehlt")
  assertContains(request.body, "refresh_token=", "Abmeldung")
  assert(mock.closed, "Verbindung wurde nicht geschlossen")
end)

----------------------------------------------------------------------------
-- Ausführung
----------------------------------------------------------------------------

print(string.format("LV 1871 – %d Tests\n", #tests))

local failures = 0
for _, item in ipairs(tests) do
  local ok, message = xpcall(item.run, function (err)
    return debug.traceback(err, 2)
  end)
  if ok then
    print("  ok      " .. item.name)
  else
    failures = failures + 1
    print("  FEHLER  " .. item.name)
    print("          " .. tostring(message):gsub("\n", "\n          "))
  end
end

print()
if failures == 0 then
  print(string.format("Alle %d Tests bestanden.", #tests))
  os.exit(0)
end
print(string.format("%d von %d Tests fehlgeschlagen.", failures, #tests))
os.exit(1)
