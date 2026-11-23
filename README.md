# MoneyMoney-Extension für die LV 1871

[![Tests](https://github.com/aknoerig/mm-lv1871/actions/workflows/tests.yml/badge.svg)](https://github.com/aknoerig/mm-lv1871/actions/workflows/tests.yml)

Fragt den aktuellen Stand von Verträgen im Kundenportal „Meine LV 1871" ab und
zeigt sie in [MoneyMoney](https://moneymoney.app) als Konto bzw. Depot – damit
Renten- und Lebensversicherungen in der Vermögensübersicht auftauchen.

> **Inoffizielles Projekt.** Es besteht keine Verbindung zur Lebensversicherung
> von 1871 a. G. München oder zu MoneyMoney. Die Extension nutzt dieselben
> Schnittstellen wie das Kundenportal im Browser; ändert die LV 1871 daran
> etwas, muss das Skript angepasst werden.

## Was die Extension macht

Für jeden laufenden Vertrag (Status `AKTIV` oder `AUFSCHUB`) wird ein Konto
angelegt:

* **Fondsgebundene Verträge** werden ein **Depot** mit der tatsächlichen
  Vermögensaufteilung als Positionen: jeder Fonds mit ISIN und Wert, dazu
  Deckungskapital und Schlussüberschuss. Die Summe entspricht dem
  Vertragsguthaben.
* **Alle übrigen Verträge** werden ein **Konto**, dessen Saldo das
  Vertragsguthaben ist.

Beendete Verträge werden übersprungen. Umsätze liefert die Extension nicht –
die Schnittstelle der LV 1871 kennt keine; es gibt nur Bestandswerte.

### Woher die Werte kommen

| Anzeige in MoneyMoney | Feld der Schnittstelle |
| --- | --- |
| Depotposition je Fonds | `garantieFonds`, `freieFondsAktuellBespart`, `freieFondsRuhend` → `fondsname`, `isin`, `wert` |
| Depotposition „Deckungskapital" | `summeDeckungskapital` |
| Depotposition „Schlussüberschuss inkl. Bewertungsreserve" | `schlussUeberschussInklusiveBewertungsreserve` |
| Depotposition „Weitere Vertragswerte" | Differenz der Positionen zum `vertragsguthaben` |
| Kontosaldo | `vertragsguthaben`, ersatzweise `rueckkauf.betragInklusiveSteuerabzug` |
| Kontoname | `produkt.bezeichnungLang`, ersatzweise die Tarifbezeichnung |
| Kontoinhaber | `rollen.versicherungsnehmer[].person` |

Weist die LV 1871 für einen klassischen Vertrag kein Guthaben aus, nutzt die
Extension den **Rückkaufswert**. Das ist der Betrag bei vorzeitiger Kündigung
und damit niedriger als das Vertragsguthaben – für die Vermögensübersicht die
vorsichtigere Zahl, aber eben eine andere Größe.

## Installation

1. `LV 1871.lua` in den Extensions-Ordner von MoneyMoney kopieren:

   ```bash
   cp "LV 1871.lua" ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application\ Support/MoneyMoney/Extensions/
   ```

   Den Ordner öffnet MoneyMoney auch über **Hilfe → Zeige Datenbank im Finder**.

2. Die Extension ist nicht von den MoneyMoney-Entwicklern signiert. Deshalb in
   MoneyMoney unter **Einstellungen → Erweiterungen** die Option
   **„Digitale Signatur von Extensions überprüfen"** ausschalten.

3. In MoneyMoney ein neues Konto anlegen, als Bank **„LV 1871"** auswählen und
   Kundennummer sowie Passwort des Kundenportals eingeben.

Ist für den Zugang eine Authenticator-App hinterlegt, fragt MoneyMoney
anschließend in einem zweiten Schritt den sechsstelligen Einmalcode ab.

Änderungen an der Datei greifen sofort, ein Neustart von MoneyMoney ist nicht
nötig.

## Wie die Anmeldung funktioniert

Die Extension meldet sich über genau dieselben Schritte an wie das Portal im
Browser: OpenID Connect Authorization Code Flow mit PKCE (S256) gegen den
Keycloak der LV 1871. Sie ruft die Anmeldeseite ab, füllt das dortige Formular,
folgt der Weiterleitung und tauscht den Autorisierungscode gegen ein Token.

Der naheliegende Umweg über `grant_type=password` funktioniert **nicht**: Der
Endpunkt nimmt die Anfrage an, antwortet für echte Kundennummern aber nach
langer Wartezeit mit `invalid_grant / Invalid user credentials`, weil die
zusätzlichen Anmeldeschritte der LV 1871 dabei nicht durchlaufen werden.

Zugangsdaten speichert die Extension nicht – darum kümmert sich der Schlüssel­bund
von MoneyMoney. Die Token liegen nur im Arbeitsspeicher und werden am Ende der
Sitzung über den Logout-Endpunkt verworfen.

### Verwendete Schnittstellen

| Zweck | Aufruf |
| --- | --- |
| Anmeldung | `auth.lv1871.de/auth/realms/lv1871-customer/protocol/openid-connect/{auth,token,logout}` |
| Vertragsliste | `GET serviceonline-gateway.lv1871.de/middleware/vertragsauskunft` |
| Vermögenswerte | `GET …/vertragsauskunft/vermoegenswerte?versicherungsnummer=…&latest=true` |
| Kalkulierte Werte | `GET …/vertragsauskunft/kalkuliertewerte?versicherungsnummer=…` |

Die Basis-URL und die Keycloak-Einstellungen stehen offen in der
Laufzeitkonfiguration des Portals unter
`serviceonline.lv1871.de/assets/config/config.json`.

## Tests

```bash
lua test/run.lua
```

Die Suite lädt `LV 1871.lua` in eine nachgebaute MoneyMoney-Umgebung
(`test/moneymoney.lua`) und beantwortet deren HTTP-Anfragen mit simulierten
Portalantworten (`test/fixtures.lua`). Es geht keine Anfrage ins Netz, und es
werden keine echten Zugangsdaten gebraucht.

Abgedeckt sind unter anderem das Ausfüllen des Keycloak-Formulars, der
Code-Tausch, die PKCE-Berechnung (gegen den Testvektor aus RFC 7636), beide
Stufen der Zwei-Faktor-Anmeldung, falsche Zugangsdaten, falscher Einmalcode,
gesperrter Zugang, erzwungene Passwortänderung, die Auswahl der Konten sowie
alle Pfade der Wertermittlung samt Fehlerfällen.

Getestet mit Lua 5.4 und 5.5. SHA-256 und Base64 sind in der Testumgebung echt
implementiert und gegen bekannte Vektoren geprüft, damit die PKCE-Prüfung nicht
nur gegen sich selbst vergleicht.

## Grenzen und Hinweise

* Die Extension liest nur – sie ändert nichts am Vertrag.
* Keycloak sperrt Zugänge nach mehreren Fehlversuchen vorübergehend und meldet
  das ebenfalls als ungültige Anmeldedaten. Bei Problemen lieber einmal im
  Browser anmelden statt wiederholt aus MoneyMoney heraus.
* Für Verträge, zu denen die LV 1871 keine Werte liefert, bricht die
  Aktualisierung mit einer entsprechenden Meldung ab, statt eine Null
  auszuweisen.
* Fehlerberichte und Verbesserungen gern als Issue oder Pull Request.

## Lizenz

[MIT](LICENSE)
