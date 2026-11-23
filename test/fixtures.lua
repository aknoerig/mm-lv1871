-- Simuliertes Kundenportal der LV 1871.
--
-- Die Seiten und Antworten sind den echten nachgebaut: Die Anmeldeseite ist
-- ein Keycloak-Formular mit der ID "formId" und den Feldern "username" und
-- "password", die zweite Stufe ein Formular mit dem Feld "otp". Die
-- Vertragsauskunft antwortet mit {data = {vertraege = ...}}, die
-- Vermögenswerte mit einem Array und fehlende Datenbestände mit dem
-- Klartext "NOT_FOUND".

local mock = require("moneymoney")

local fixtures = {}

local AUTH   = "https://auth.lv1871.de/auth/realms/lv1871-customer"
local ACTION = AUTH .. "/login-actions/authenticate"

fixtures.code = "f7b1c0de-2a44-4d9e-9a1f-8c21d6b5e0aa.3c9a1b77-5d2e-4f80-b6aa-1e4d7c0f9b31"

----------------------------------------------------------------------------
-- Seiten
----------------------------------------------------------------------------

local LOGIN_ACTION = ACTION .. "?session_code=cc5ypqxV3PhfUdh6kBI&execution=9136e9aa"
                            .. "&client_id=lv1871-kundenportal-ui&tab_id=QR8jMoCCar0"
local OTP_ACTION   = ACTION .. "?session_code=Hk2mTPl9ZzXc4vQnR1a&execution=4b7c1d02"
                            .. "&client_id=lv1871-kundenportal-ui&tab_id=QR8jMoCCar0"

local pageLogin = mock.page("seite:anmeldung", {
  form = {action = LOGIN_ACTION, inputs = {"username", "password"}}
})

local pageLoginError = mock.page("seite:anmeldung-fehler", {
  form     = {action = LOGIN_ACTION, inputs = {"username", "password"}},
  messages = {lvMessageTextId = "Ungültige Anmeldedaten. Bitte prüfen Sie Kundennummer und Passwort."}
})

local pageLoginLocked = mock.page("seite:anmeldung-gesperrt", {
  form     = {action = LOGIN_ACTION, inputs = {"username", "password"}},
  messages = {lvMessageTextId = "Ihr Zugang ist vorübergehend gesperrt. Bitte versuchen Sie es später erneut."}
})

local pageOTP = mock.page("seite:einmalcode", {
  form = {action = OTP_ACTION, inputs = {"otp"}}
})

local pageOTPError = mock.page("seite:einmalcode-fehler", {
  form     = {action = OTP_ACTION, inputs = {"otp"}},
  messages = {lvMessageTextId = "Ungültiger Einmalcode."}
})

local pagePasswordUpdate = mock.page("seite:passwort-aendern", {
  form = {action = AUTH .. "/login-actions/required-action?execution=UPDATE_PASSWORD",
          inputs = {"password-new", "password-confirm"}}
})

-- Die SPA, auf der die Weiterleitung nach erfolgreicher Anmeldung landet.
local pagePortal = mock.page("seite:portal", {})

----------------------------------------------------------------------------
-- Vertragsdaten
----------------------------------------------------------------------------

local function contractsPayload ()
  return {
    data = {
      bankkonten = {},
      vertraege = {
        {
          -- Fondsgebundene Rentenversicherung: wird ein Depot
          bestandssystem     = "LIVES",
          beschaffungsstatus = "VOLLSTAENDIG",
          produkt = {bezeichnungKurz = "MeinPlan Invest",
                     bezeichnungLang = "MeinPlan Rente Invest"},
          vertrag = {
            versicherungsnummer = 12345678,
            produktId = "FRV",
            art    = {vertragstyp = "FONDS"},
            status = {art = "AKTIV"},
            tarif  = {kurzbezeichnung = "FRV", tarifTyp = "G3"},
            beitrag = {beitragBrutto = 250.0, zahlungsweise = "MONATLICH"},
            versicherungsumfang = {versicherungsbeginn = "2015-04-01",
                                   versicherungsende   = "2045-04-01"},
            garantierteWerte = {jahresrente = 4800.0}
          },
          rollen = {
            versicherungsnehmer = {
              {person = {kundennummer = 4711, vorname = "Erika", nachname = "Mustermann"}}
            }
          }
        },
        {
          -- Klassische Rentenversicherung ohne produkt-Objekt: wird ein Konto
          bestandssystem     = "LIVES",
          beschaffungsstatus = "VOLLSTAENDIG",
          vertrag = {
            versicherungsnummer = 87654321,
            art    = {vertragstyp = "KLASSISCH"},
            status = {art = "AKTIV"},
            tarif  = {kurzbezeichnung = "RV12"},
            beitrag = {beitragBrutto = 100.0, zahlungsweise = "JAEHRLICH"}
          }
        },
        {
          -- Beendeter Vertrag: taucht in MoneyMoney nicht auf
          vertrag = {
            versicherungsnummer = 11112222,
            art    = {vertragstyp = "KLASSISCH"},
            status = {art = "BEENDET"},
            tarif  = {kurzbezeichnung = "RV12"}
          }
        }
      }
    }
  }
end

local function fundAssets ()
  return {{
    wirksamkeitsdatum = "2026-11-01",
    vertragsguthaben  = 48250.75,
    summeDeckungskapital = 12000.00,
    summeGarantiertesVermoegen = 8000.50,
    garantieFonds = {fondsname = "LV 1871 Garantiefonds",
                     isin = "DE0001234567", wert = 8000.50,
                     anteilAmFondsvermoegen = 100.0},
    summeFreiesFondsvermoegenAktuellBespart = 26000.25,
    freieFondsAktuellBespart = {
      {fondsname = "MSCI World ETF", isin = "IE00B4L5Y983",
       wert = 20000.25, anteilAmFondsvermoegen = 76.9},
      {fondsname = "Europa Aktien", isin = "LU0011111111",
       wert = 6000.00, anteilAmFondsvermoegen = 23.1}
    },
    schlussUeberschussInklusiveBewertungsreserve = 2250.00
  }}
end

----------------------------------------------------------------------------
-- Routing
----------------------------------------------------------------------------

local function tokenResponse (lifetime)
  return mock.json{
    access_token  = "eyJhbGciOiJSUzI1NiIsInR5cCIgOiAiSldUIn0.ACCESS",
    refresh_token = "eyJhbGciOiJIUzUxMiIsInR5cCIgOiAiSldUIn0.REFRESH",
    token_type    = "Bearer",
    expires_in    = lifetime,
    scope         = "openid profile email"
  }
end

local function insuranceNumber (url)
  return url:match("versicherungsnummer=(%d+)")
end

function fixtures.handle (method, url, body, headers)
  local scenario = fixtures.scenario

  -- Anmeldeseite abrufen
  if url:find("/protocol/openid%-connect/auth%?") then
    return pageLogin
  end

  -- Anmeldeformular bzw. Einmalcode abschicken
  if url:find("login-actions/authenticate", 1, true) then
    local isFirstStep = url == LOGIN_ACTION
    local outcome = isFirstStep and scenario.loginOutcome or scenario.otpOutcome

    if outcome == "wrongCredentials" then
      return pageLoginError
    elseif outcome == "locked" then
      return pageLoginLocked
    elseif outcome == "otp" then
      return pageOTP
    elseif outcome == "wrongCode" then
      return pageOTPError
    elseif outcome == "passwordUpdate" then
      return pagePasswordUpdate
    elseif outcome == "silentFailure" then
      return pageLogin
    end

    -- Erfolg: Keycloak leitet auf die Redirect-URI mit dem Code weiter,
    -- MoneyMoney folgt der Weiterleitung.
    local target = "https://serviceonline.lv1871.de/meineLV/uebersicht?state=xyz&session_state=abc&code="
                   .. fixtures.code
    return pagePortal, target
  end

  -- Token-Endpunkt
  if url:find("/protocol/openid%-connect/token$") then
    local grant = body and body:match("grant_type=([%w_%%%-]+)")
    if grant == "authorization_code" then
      assert(body:find("code=" .. fixtures.code:gsub("%-", "%%-"), 1, false),
             "Autorisierungscode fehlt im Token-Request")
      assert(body:find("code_verifier=", 1, true), "code_verifier fehlt im Token-Request")
      if scenario.tokenOutcome == "denied" then
        return mock.json{error = "invalid_grant", error_description = "Code not valid"}
      end
      return tokenResponse(scenario.tokenLifetime)
    elseif grant == "refresh_token" then
      return tokenResponse(300)
    end
    error("unerwarteter Token-Request: " .. tostring(body))
  end

  if url:find("/protocol/openid%-connect/logout") then
    return ""
  end

  -- Vertragsauskunft
  if url:find("/vertragsauskunft/vermoegenswerte", 1, true) then
    local assets = scenario.assets[insuranceNumber(url)]
    return assets and mock.json(assets) or "NOT_FOUND"
  end

  if url:find("/vertragsauskunft/kalkuliertewerte", 1, true) then
    local values = scenario.calculated[insuranceNumber(url)]
    return values and mock.json(values) or "NOT_FOUND"
  end

  if url:find("/vertragsauskunft", 1, true) then
    if scenario.contracts == nil then
      return "NOT_FOUND"
    end
    return mock.json(scenario.contracts)
  end

  error("unerwartete URL: " .. url)
end

----------------------------------------------------------------------------

-- Setzt Szenario und Mock auf den Normalfall zurück.
function fixtures.reset ()
  fixtures.scenario = {
    loginOutcome  = "success",
    otpOutcome    = "success",
    tokenOutcome  = "granted",
    tokenLifetime = 300,
    contracts     = contractsPayload(),
    assets        = {["12345678"] = fundAssets()},
    calculated    = {["87654321"] = {rueckkauf = {betragInklusiveSteuerabzug = 15750.42,
                                                  zeitpunkt = "2026-12-01"}}}
  }
  mock.install(fixtures.handle)
  return fixtures.scenario
end

fixtures.pages = {
  login    = pageLogin,
  otp      = pageOTP,
  portal   = pagePortal
}

return fixtures
