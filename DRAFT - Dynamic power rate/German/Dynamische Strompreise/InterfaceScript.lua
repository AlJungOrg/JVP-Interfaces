-------------------------------------------------------------------------------
-- InterfaceScript.lua
-- @script InterfaceScript
--
-- JUNG Visu Pro (JVP) Prozessanschluss "Strompreise".
--
-- Fragt Day-Ahead-Boersenpreise fuer heute und morgen ab und stellt sie
-- stundenaufgeloest sowie als Tageskennzahlen (Min/Max/Durchschnitt, aktueller
-- Preis, guenstigstes Zeitfenster, "gerade guenstig"-Flag) als Datenpunkte fuer
-- die Visualisierung bereit. Unterstuetzte Laender/Quellen:
--
--   DE, AT  - aWATTar API (api.awattar.de / .at), EUR/MWh, volle Tagesreihe.
--   FR, NL  - Energy-Charts.info API (Fraunhofer ISE), EUR/MWh, volle Tagesreihe.
--             Daten fuer FR/NL sind CC BY 4.0 lizenziert (Attribution noetig).
--   KR      - Elecz.com (KPX SMP), KRW/kWh, NUR aktueller Preis (keine
--             Tagesreihe verfuegbar) - TODAY.CURRENT/CURRENTHOUR werden
--             gesetzt, alle anderen Preisdatenpunkte bleiben leer/0.
--
-- Nicht unterstuetzt: China (CN) - keine oeffentliche/kostenlose Day-Ahead-API
-- gefunden. Spanien (ES) und Litauen (LT) liefert Energy-Charts.info zwar
-- technisch, aber nur unter einer "privat/intern"-Lizenz (keine externe bzw.
-- kommerzielle Nutzung) - daher hier bewusst nicht angebunden.
--
-- Target runtime: Lua 5.1.
-------------------------------------------------------------------------------

require "InterfaceScriptCommonLibrary"

local mg_bDebug = false
mg_nPollSeconds = 60              -- muss zu INFO POLLTIME (60000 ms) passen

HTTP_RQ = nil                     -- HTTP-Ressource, in Init() geoeffnet

local g_bForceRefresh          = true   -- erzwingt Abruf beim naechsten Poll()
local g_nSecondsUntilNextFetch = 0      -- Sekunden bis zum naechsten geplanten Abrufversuch
local g_nConsecutiveFailures   = 0      -- fuer Retry-Backoff bei Fehlern
local g_strLastPollDate        = nil    -- letztes bekanntes Datum (TT.MM.JJJJ), fuer Tageswechsel-Erkennung

-------------------------------------------------------------------------------
-- Hilfsfunktionen
-------------------------------------------------------------------------------

--- Read a datapoint as a number, tolerant of German comma / unit suffixes.
-- @param oNode table  Elternknoten (z.B. E.PVTable["CONFIGURATION"]).
-- @param strName string  SCRIPTNAME des Datenpunkts.
-- @return number
local function getNum( oNode, strName )
	if ((oNode == nil) or (oNode[strName] == nil)) then return 0 end
	local s = oNode[strName]:GetValue()
	if (s == nil) then return 0 end
	s = tostring(s):gsub( ",", "." )
	local n = tonumber( s )
	if (n ~= nil) then return n end
	return tonumber( (s:match( "[-+]?%d+%.?%d*" )) ) or 0
end

--- Read a datapoint as text ("" if missing).
-- @param oNode table
-- @param strName string
-- @return string
local function getStr( oNode, strName )
	if ((oNode == nil) or (oNode[strName] == nil)) then return "" end
	return oNode[strName]:GetValue() or ""
end

--- Write a datapoint (guarded, no-op if the datapoint doesn't exist).
-- @param oNode table
-- @param strName string
-- @param value any  wird mit tostring() in Text gewandelt.
local function setVal( oNode, strName, value )
	if ((oNode ~= nil) and (oNode[strName] ~= nil)) then
		oNode[strName]:SetValue( tostring(value), constValueChange )
	end
end

--- Current time as text in the project format.
-- @return string
local function nowStr()
	return os.date( "%d.%m.%Y %H:%M:%S", os.time() )
end

--- Preis mit zwei Nachkommastellen als Text formatieren.
-- @param n number
-- @return string
local function fmt2( n )
	return string.format( "%.2f", n )
end

--- Boersenpreis (EUR/MWh) in einen Endkundenpreis (ct/kWh) umrechnen.
-- 1 EUR/MWh entspricht 0.1 ct/kWh. Aufschlag (Netzentgelte/Marge) wird addiert,
-- danach die MwSt auf die Summe angewendet. Nur fuer die EUR/MWh-Quellen
-- (DE/AT/FR/NL) relevant - fuer KR (KRW/kWh) wird der Rohwert unveraendert
-- uebernommen, siehe UpdateCurrentPriceKorea().
-- @param nMarketEurMwh number  Boersenpreis in EUR/MWh (kann negativ sein).
-- @param nSurchargeCt number  Aufschlag in ct/kWh.
-- @param nVatPercent number  Mehrwertsteuersatz in Prozent.
-- @return number  Endkundenpreis in ct/kWh.
local function toConsumerPriceCt( nMarketEurMwh, nSurchargeCt, nVatPercent )
	local rawCt = nMarketEurMwh / 10.0
	local net   = rawCt + nSurchargeCt
	return net * (1 + (nVatPercent / 100))
end

--- aWATTar-JSON-Antwort ("data": [{start_timestamp, end_timestamp, marketprice, unit}, ...])
-- ohne vollen JSON-Parser auswerten (fester, dokumentierter Feldreihenfolge).
-- Funktioniert unabhaengig von der gelieferten Zeitaufloesung (60/30/15 Minuten),
-- da nur Zeitstempel+Preis je Eintrag extrahiert werden.
-- @param strData string  Rohes JSON aus der HTTP-Antwort.
-- @return table  Liste von { ts = <ms epoch>, price = <EUR/MWh> }, aufsteigend sortiert.
local function parseAwattarData( strData )
	local list = {}
	if (strData == nil) then return list end
	for ts, price in strData:gmatch( '"start_timestamp"%s*:%s*(%-?%d+).-"marketprice"%s*:%s*(%-?%d+%.?%d*)' ) do
		local nTs    = tonumber( ts )
		local nPrice = tonumber( price )
		if ((nTs ~= nil) and (nPrice ~= nil)) then
			table.insert( list, { ts = nTs, price = nPrice } )
		end
	end
	table.sort( list, function(a, b) return a.ts < b.ts end )
	return list
end

--- Energy-Charts.info-JSON-Antwort auswerten. Anders als bei aWATTar liegen
-- Zeitstempel und Preise dort als zwei getrennte, parallele Arrays vor:
-- {"unix_seconds": [..], "price": [.. oder null ..], "unit": "EUR / MWh"}.
-- "null"-Eintraege (keine Daten fuer diesen Slot) werden uebersprungen.
-- @param strData string  Rohes JSON aus der HTTP-Antwort.
-- @return table  Liste von { ts = <ms epoch>, price = <EUR/MWh> }, aufsteigend sortiert.
local function parseEnergyChartsData( strData )
	local list = {}
	if (strData == nil) then return list end

	local strTsArray    = strData:match( '"unix_seconds"%s*:%s*%[(.-)%]' )
	local strPriceArray = strData:match( '"price"%s*:%s*%[(.-)%]' )
	if ((strTsArray == nil) or (strPriceArray == nil)) then return list end

	local tblTs = {}
	for tok in (strTsArray .. ","):gmatch( "%s*([^,]*)%s*," ) do
		if (tok ~= "") then table.insert( tblTs, tonumber(tok) ) end
	end

	local tblPrice = {}
	for tok in (strPriceArray .. ","):gmatch( "%s*([^,]*)%s*," ) do
		if (tok ~= "") then
			if (tok == "null") then
				table.insert( tblPrice, false )   -- expliziter "keine Daten"-Platzhalter
			else
				table.insert( tblPrice, tonumber(tok) )
			end
		end
	end

	local n = math.min( #tblTs, #tblPrice )
	for i = 1, n do
		local nTs    = tblTs[i]
		local vPrice = tblPrice[i]
		if ((nTs ~= nil) and (type(vPrice) == "number")) then
			table.insert( list, { ts = nTs * 1000, price = vPrice } )   -- Sekunden -> ms
		end
	end
	table.sort( list, function(a, b) return a.ts < b.ts end )
	return list
end

--- Native Zeitaufloesung der Antwort in Minuten schaetzen (Differenz der ersten
-- zwei Zeitstempel). Faellt auf 60 zurueck, wenn nicht bestimmbar.
-- @param tblEntries table  Ergebnis von parseAwattarData()/parseEnergyChartsData(), aufsteigend sortiert.
-- @return number  Aufloesung in Minuten (z.B. 60 oder 15).
local function detectResolutionMinutes( tblEntries )
	if ((tblEntries == nil) or (#tblEntries < 2)) then return 60 end
	local nDiffMs = tblEntries[2].ts - tblEntries[1].ts
	if (nDiffMs <= 0) then return 60 end
	local nMin = nDiffMs / 60000
	if (nMin < 1) then nMin = 1 end
	return nMin
end

--- Guenstigstes zusammenhaengendes Zeitfenster aus stundengenauen Preisen suchen.
-- Fenster, die eine Stunde ohne Daten enthalten, werden uebersprungen; findet
-- sich kein vollstaendig belegtes Fenster der gewuenschten Laenge, wird nil
-- zurueckgegeben (Aufrufer laesst BESTSTART/BESTAVG dann unveraendert).
-- @param tblPricesByHour table  [0..23] -> Preis in ct/kWh oder nil.
-- @param nWindowHours number  Fensterlaenge in Stunden (1..24).
-- @return number|nil, number|nil  Startstunde, Durchschnittspreis im Fenster.
local function findBestWindow( tblPricesByHour, nWindowHours )
	if ((nWindowHours == nil) or (nWindowHours < 1)) then nWindowHours = 1 end
	if (nWindowHours > 24) then nWindowHours = 24 end

	local nBestStart, nBestAvg = nil, nil
	for nStart = 0, 24 - nWindowHours do
		local nSum = 0
		local bComplete = true
		for h = nStart, nStart + nWindowHours - 1 do
			local v = tblPricesByHour[h]
			if (v == nil) then bComplete = false; break end
			nSum = nSum + v
		end
		if (bComplete) then
			local nAvg = nSum / nWindowHours
			if ((nBestAvg == nil) or (nAvg < nBestAvg)) then
				nBestStart = nStart
				nBestAvg = nAvg
			end
		end
	end
	return nBestStart, nBestAvg
end

--- Stundenwerte, Min/Max/Durchschnitt, guenstigstes Zeitfenster und (fuer
-- "heute") den aktuellen Preis + "guenstig"-Flag in die Datenpunkte eines
-- Tagesordners (TODAY/TOMORROW) schreiben.
--
-- tblHourAcc enthaelt je Stunde einen Akkumulator { sum = ..., count = ... },
-- damit auch mehrere Rohwerte pro Stunde (15-/30-Minuten-Aufloesung) korrekt
-- zu einem Stundenmittel zusammengefasst werden, statt sich gegenseitig zu
-- ueberschreiben. Stunden ohne Daten werden explizit geleert (nicht mit einem
-- veralteten Wert stehen gelassen) - relevant an Tagen mit Zeitumstellung
-- (23- bzw. 25-Stunden-Tag) und fuer Quellen ohne Tagesreihe (KR: leeres
-- tblHourAcc = {} loescht alle Stundenwerte sauber).
--
-- WICHTIG: JVP verlangt global eindeutige SCRIPTNAMEs innerhalb der gesamten
-- InterfaceDescription.xml (nicht nur je Elternordner). Da TODAY und TOMORROW
-- inhaltlich dieselben Felder (DATE, MIN, H00..H23, ...) besitzen, sind die
-- Datenpunkte in TOMORROW mit dem Praefix "TOM_" versehen (z.B. "TOM_H23").
-- Der Aufrufer uebergibt dieses Praefix ueber strPrefix.
--
-- @param oNode table  E.PVTable["TODAY"] oder E.PVTable["TOMORROW"].
-- @param tblHourAcc table  [0..23] -> { sum = number, count = number } oder nil.
-- @param strDate string  Datum als TT.MM.JJJJ.
-- @param bIsToday boolean  true fuer TODAY (schreibt zusaetzlich CURRENT/CURRENTHOUR/IS_CHEAP).
-- @param nWindowHours number  Laenge des gesuchten guenstigsten Zeitfensters (Stunden).
-- @param nThresholdCt number  Schwellenwert fuer IS_CHEAP (ct/kWh), nur fuer "heute" relevant.
-- @param strPrefix string|nil  SCRIPTNAME-Praefix fuer DATE/AVAILABLE/MIN/.../H00-H23 (leer fuer TODAY, "TOM_" fuer TOMORROW).
local function writeDay( oNode, tblHourAcc, strDate, bIsToday, nWindowHours, nThresholdCt, strPrefix )
	if (oNode == nil) then return end
	strPrefix = strPrefix or ""

	local tblPricesByHour = {}
	local nCount, nSum, nMin, nMax, nMinHour, nMaxHour = 0, 0, nil, nil, nil, nil

	for h = 0, 23 do
		local acc = tblHourAcc[h]
		local key = strPrefix .. string.format( "H%02d", h )
		if ((acc ~= nil) and (acc.count > 0)) then
			local v = acc.sum / acc.count
			tblPricesByHour[h] = v
			setVal( oNode, key, fmt2(v) )
			nCount = nCount + 1
			nSum = nSum + v
			if ((nMin == nil) or (v < nMin)) then nMin = v; nMinHour = h end
			if ((nMax == nil) or (v > nMax)) then nMax = v; nMaxHour = h end
		else
			-- keine Daten fuer diese Stunde (Zeitumstellung oder Quelle ohne
			-- Tagesreihe) -> Feld leeren statt einen veralteten Wert zu zeigen.
			setVal( oNode, key, "" )
		end
	end

	setVal( oNode, strPrefix.."DATE", strDate )
	setVal( oNode, strPrefix.."AVAILABLE", (nCount > 0) and 1 or 0 )

	if (nCount > 0) then
		setVal( oNode, strPrefix.."MIN", fmt2(nMin) )
		setVal( oNode, strPrefix.."MAX", fmt2(nMax) )
		setVal( oNode, strPrefix.."AVG", fmt2(nSum / nCount) )
		setVal( oNode, strPrefix.."MINHOUR", nMinHour )
		setVal( oNode, strPrefix.."MAXHOUR", nMaxHour )

		local nBestStart, nBestAvg = findBestWindow( tblPricesByHour, nWindowHours )
		if (nBestStart ~= nil) then
			setVal( oNode, strPrefix.."BESTSTART", nBestStart )
			setVal( oNode, strPrefix.."BESTAVG", fmt2(nBestAvg) )
		end
	else
		setVal( oNode, strPrefix.."MIN", "" )
		setVal( oNode, strPrefix.."MAX", "" )
		setVal( oNode, strPrefix.."AVG", "" )
		setVal( oNode, strPrefix.."MINHOUR", "" )
		setVal( oNode, strPrefix.."MAXHOUR", "" )
		setVal( oNode, strPrefix.."BESTSTART", "" )
		setVal( oNode, strPrefix.."BESTAVG", "" )
	end

	if (bIsToday) then
		local nCurHour = tonumber( os.date( "%H", os.time() ) )
		setVal( oNode, "CURRENTHOUR", nCurHour )
		if ((nCurHour ~= nil) and (tblPricesByHour[nCurHour] ~= nil)) then
			local nCur = tblPricesByHour[nCurHour]
			setVal( oNode, "CURRENT", fmt2(nCur) )
			setVal( oNode, "IS_CHEAP", (nCur < nThresholdCt) and 1 or 0 )
		end
	end
end

--- CURRENT/CURRENTHOUR/IS_CHEAP in TODAY zwischen zwei Preisabrufen aus dem
-- bereits geschriebenen Stundenwert (H00..H23) nachfuehren, damit der
-- "jetzt"-Preis exakt zur vollen Stunde wechselt, ohne dafuer neu abzufragen.
-- Fuer Quellen ohne Tagesreihe (KR) ist H<Stunde> immer leer, die Funktion ist
-- dort also ein No-Op - CURRENT wird fuer KR ausschliesslich in
-- UpdateCurrentPriceKorea() bei jedem tatsaechlichen Poll gesetzt.
local function refreshCurrentFromCache()
	local oConfig = E.PVTable["CONFIGURATION"]
	local oToday  = E.PVTable["TODAY"]
	if (oToday == nil) then return end
	local nCurHour = tonumber( os.date( "%H", os.time() ) )
	if (nCurHour == nil) then return end
	local key = string.format( "H%02d", nCurHour )
	if (oToday[key] ~= nil) then
		local strVal = oToday[key]:GetValue()
		if ((strVal ~= nil) and (strVal ~= "")) then
			setVal( oToday, "CURRENT", strVal )
			local nCur = tonumber( ((tostring(strVal)):gsub(",", ".")) )
			local nThreshold = getNum( oConfig, "THRESHOLD_CT" )
			if (nCur ~= nil) then
				setVal( oToday, "IS_CHEAP", (nCur < nThreshold) and 1 or 0 )
			end
		end
	end
	setVal( oToday, "CURRENTHOUR", nCurHour )
end

--- Gemeinsame HTTP-GET-Ausfuehrung fuer alle Quellen.
-- @param strUrl string
-- @return boolean, number|nil, string|nil, string|nil  bOk, nHttpStatus, strErr, strData
local function httpGet( strUrl )
	if (HTTP_RQ == nil) then
		return false, nil, "HTTP-Ressource nicht verfuegbar", nil
	end
	HTTP_RQ:RemoveHeaders()
	HTTP_RQ:SetURL( strUrl )
	-- HTTP_GET ist eine von der JVP-Laufzeit bereitgestellte Konstante (analog HTTP_POST).
	HTTP_RQ:SendRequest( HTTP_GET, "" )
	local nReturnCode, strErr, nHttpStatus, strData = HTTP_RQ:GetRxData()
	if ((nReturnCode == nil) or (nReturnCode ~= 0) or (nHttpStatus ~= 200) or (strData == nil)) then
		return false, nHttpStatus, strErr, nil
	end
	return true, nHttpStatus, nil, strData
end

--- Day-Ahead-Preisabruf fuer Laender mit voller Tagesreihe (DE, AT, FR, NL).
-- Ruft die passende API auf, parst die Antwort, verteilt auf "heute"/"morgen"
-- und aktualisiert die Datenpunkte. Bei Fehlern bleiben die zuletzt bekannten
-- Werte unveraendert stehen; nur STATUS.ERROR/ERRORTEXT werden gesetzt.
-- @param strCountry string  "DE", "AT", "FR" oder "NL".
-- @return boolean  true bei Erfolg, false bei einem behandelten Fehler.
local function UpdateDayAheadPrices( strCountry )
	local oConfig = E.PVTable["CONFIGURATION"]
	local oStatus = E.PVTable["STATUS"]
	local oToday    = E.PVTable["TODAY"]
	local oTomorrow = E.PVTable["TOMORROW"]

	local nSurcharge   = getNum( oConfig, "SURCHARGE_CT" )
	local nVat         = getNum( oConfig, "VAT_PERCENT" )
	local nThreshold   = getNum( oConfig, "THRESHOLD_CT" )
	local nWindowHours = getNum( oConfig, "WINDOW_HOURS" )
	if (nWindowHours < 1) then nWindowHours = 4 end   -- Default: 4h-Fenster

	-- Zeitfenster: lokale Mitternacht "heute" bis +3 Tage (Puffer).
	local nNow = os.time()
	local tMidnight = os.date( "*t", nNow )
	tMidnight.hour = 0; tMidnight.min = 0; tMidnight.sec = 0
	local nStartSec = os.time( tMidnight )
	local nEndSec   = nStartSec + 3 * 86400

	local strUrl, fnParse
	if ((strCountry == "DE") or (strCountry == "AT")) then
		local strHost = (strCountry == "AT") and "api.awattar.at" or "api.awattar.de"
		strUrl = "https://" .. strHost .. "/v1/marketdata?start=" .. tostring(nStartSec * 1000) .. "&end=" .. tostring(nEndSec * 1000)
		fnParse = parseAwattarData
	else
		-- FR, NL: Energy-Charts.info (bzn-Code entspricht direkt dem Laendercode)
		strUrl = "https://api.energy-charts.info/price?bzn=" .. strCountry .. "&start=" .. tostring(nStartSec) .. "&end=" .. tostring(nEndSec)
		fnParse = parseEnergyChartsData
	end

	local bOk, nHttpStatus, strErr, strData = httpGet( strUrl )
	if (not bOk) then
		setVal( oStatus, "ERROR", 1 )
		setVal( oStatus, "ERRORTEXT", "HTTP-Fehler " .. tostring(nHttpStatus) .. ": " .. tostring(strErr) )
		return false
	end

	local tblEntries = fnParse( strData )
	if (#tblEntries == 0) then
		setVal( oStatus, "ERROR", 1 )
		setVal( oStatus, "ERRORTEXT", "Keine Preisdaten in der Antwort gefunden" )
		return false
	end

	setVal( oStatus, "SOURCE_RESOLUTION_MIN", string.format( "%d", detectResolutionMinutes(tblEntries) ) )
	setVal( oStatus, "PRICE_UNIT", "ct/kWh" )

	local strTodayDate    = os.date( "%d.%m.%Y", nNow )
	local strTomorrowDate = os.date( "%d.%m.%Y", nNow + 86400 )

	-- Je Stunde ein Akkumulator { sum, count }, damit mehrere Rohwerte pro
	-- Stunde (15-/30-Minuten-Aufloesung) gemittelt statt ueberschrieben werden.
	local tblToday, tblTomorrow = {}, {}

	for _, e in ipairs( tblEntries ) do
		local nSec = e.ts / 1000
		local strDate = os.date( "%d.%m.%Y", nSec )
		local nHour = tonumber( os.date( "%H", nSec ) )
		if (nHour ~= nil) then
			local nPrice = toConsumerPriceCt( e.price, nSurcharge, nVat )
			local tblTarget = nil
			if (strDate == strTodayDate) then
				tblTarget = tblToday
			elseif (strDate == strTomorrowDate) then
				tblTarget = tblTomorrow
			end
			if (tblTarget ~= nil) then
				local acc = tblTarget[nHour]
				if (acc == nil) then
					acc = { sum = 0, count = 0 }
					tblTarget[nHour] = acc
				end
				acc.sum = acc.sum + nPrice
				acc.count = acc.count + 1
			end
		end
	end

	writeDay( oToday, tblToday, strTodayDate, true, nWindowHours, nThreshold )
	writeDay( oTomorrow, tblTomorrow, strTomorrowDate, false, nWindowHours, nThreshold, "TOM_" )

	setVal( oStatus, "ERROR", 0 )
	setVal( oStatus, "ERRORTEXT", "" )
	setVal( oStatus, "LASTUPDATE", nowStr() )
	return true
end

--- Preisabruf fuer Korea (KR) ueber Elecz.com (KPX SMP). Liefert nur den
-- aktuellen Spotpreis, keine Tagesreihe: TODAY.H00..H23/MIN/MAX/AVG/
-- BESTSTART/BESTAVG und die komplette TOMORROW-Struktur werden geleert
-- (AVAILABLE=0), nur TODAY.CURRENT/CURRENTHOUR werden gesetzt. Der Rohwert
-- (KRW/kWh, KPX SMP-Grosshandelspreis) wird unveraendert uebernommen - kein
-- Aufschlag/MwSt (das sind europaeische Endkundenpreis-Konzepte) und kein
-- IS_CHEAP-Vergleich (CONFIGURATION.THRESHOLD_CT ist in ct/kWh, nicht KRW).
-- @return boolean  true bei Erfolg, false bei einem behandelten Fehler.
local function UpdateCurrentPriceKorea()
	local oStatus   = E.PVTable["STATUS"]
	local oToday    = E.PVTable["TODAY"]
	local oTomorrow = E.PVTable["TOMORROW"]

	local nNow = os.time()
	local strTodayDate    = os.date( "%d.%m.%Y", nNow )
	local strTomorrowDate = os.date( "%d.%m.%Y", nNow + 86400 )

	-- Tagesreihen-Felder sauber leeren (keine Daten fuer diese Quelle verfuegbar).
	writeDay( oToday, {}, strTodayDate, false, 4, 0 )
	writeDay( oTomorrow, {}, strTomorrowDate, false, 4, 0, "TOM_" )
	setVal( oToday, "IS_CHEAP", "" )

	local bOk, nHttpStatus, strErr, strData = httpGet( "https://elecz.com/signal/spot?zone=KR" )
	if (not bOk) then
		setVal( oStatus, "ERROR", 1 )
		setVal( oStatus, "ERRORTEXT", "HTTP-Fehler " .. tostring(nHttpStatus) .. ": " .. tostring(strErr) )
		return false
	end

	local nPrice = tonumber( strData:match( '"price"%s*:%s*(%-?%d+%.?%d*)' ) )
	local strUnit = strData:match( '"unit"%s*:%s*"([^"]*)"' ) or "KRW/kWh"

	if (nPrice == nil) then
		setVal( oStatus, "ERROR", 1 )
		setVal( oStatus, "ERRORTEXT", "Keine Preisdaten in der Antwort gefunden" )
		return false
	end

	setVal( oToday, "CURRENT", fmt2(nPrice) )
	setVal( oToday, "CURRENTHOUR", tonumber( os.date( "%H", nNow ) ) )
	setVal( oStatus, "SOURCE_RESOLUTION_MIN", "" )
	setVal( oStatus, "PRICE_UNIT", strUnit )
	setVal( oStatus, "ERROR", 0 )
	setVal( oStatus, "ERRORTEXT", "" )
	setVal( oStatus, "LASTUPDATE", nowStr() )
	return true
end

--- Einstiegspunkt fuer einen kompletten Preisabruf: waehlt anhand von
-- CONFIGURATION.COUNTRY die passende Quelle (Tagesreihe oder Korea-Sonderfall).
-- @return boolean  true bei Erfolg, false bei einem behandelten Fehler.
function UpdatePrices()
	local oConfig = E.PVTable["CONFIGURATION"]
	local strCountry = getStr( oConfig, "COUNTRY" )
	if ((strCountry == nil) or (strCountry == "")) then strCountry = "DE" end
	strCountry = strCountry:upper()

	if (strCountry == "KR") then
		return UpdateCurrentPriceKorea()
	end

	if ((strCountry ~= "DE") and (strCountry ~= "AT") and (strCountry ~= "FR") and (strCountry ~= "NL")) then
		strCountry = "DE"   -- unbekannter/nicht unterstuetzter Code -> sicherer Default
	end

	return UpdateDayAheadPrices( strCountry )
end

-- ===========================================================================
-- JVP lifecycle
-- ===========================================================================

function Init()
	E:trace( "---- Strompreise: Init ----" )
	HTTP_RQ = E.ResourceTable["HTTP"]
	if (HTTP_RQ ~= nil) then HTTP_RQ:Open() end
	g_bForceRefresh = true
	g_nSecondsUntilNextFetch = 0
	g_nConsecutiveFailures = 0
	g_strLastPollDate = nil
end

function Exit()
	E:trace( "---- Strompreise: Exit ----" )
	if (HTTP_RQ ~= nil) then HTTP_RQ:Close() end
end

function Poll()
	local oConfig = E.PVTable["CONFIGURATION"]
	local nPollMinutes = getNum( oConfig, "POLL_MINUTES" )
	if (nPollMinutes < 5) then nPollMinutes = 15 end   -- Default / Mindestwert (Fair-Use aller Quellen: <=100 Abrufe/Tag)
	local nPollSecondsCfg = nPollMinutes * 60

	g_nSecondsUntilNextFetch = g_nSecondsUntilNextFetch - mg_nPollSeconds

	local strTodayDate = os.date( "%d.%m.%Y", os.time() )
	local bDateRolled = (g_strLastPollDate ~= nil) and (g_strLastPollDate ~= strTodayDate)

	if (g_bForceRefresh or bDateRolled or (g_nSecondsUntilNextFetch <= 0)) then
		local bPcallOk, bUpdateOk = pcall( UpdatePrices )
		if (not bPcallOk) then
			local oStatus = E.PVTable["STATUS"]
			setVal( oStatus, "ERROR", 1 )
			setVal( oStatus, "ERRORTEXT", "Skriptfehler: " .. tostring(bUpdateOk) )
			bUpdateOk = false
		end

		if (bUpdateOk == true) then
			g_nConsecutiveFailures = 0
			g_nSecondsUntilNextFetch = nPollSecondsCfg
		else
			-- Retry-Backoff: nach Fehlern zeitnah erneut versuchen (30s, 60s, 120s, ...),
			-- aber nie oefter als das konfigurierte Abrufintervall.
			g_nConsecutiveFailures = g_nConsecutiveFailures + 1
			local nExp = g_nConsecutiveFailures - 1
			if (nExp > 5) then nExp = 5 end
			local nBackoff = 30 * (2 ^ nExp)
			if (nBackoff > nPollSecondsCfg) then nBackoff = nPollSecondsCfg end
			g_nSecondsUntilNextFetch = nBackoff
		end

		g_bForceRefresh = false
	else
		refreshCurrentFromCache()
	end

	g_strLastPollDate = strTodayDate
end

function OnValueRead( oVarPath, nReason )
	local v = oVarPath:_getLeaf()
	if (nil == v) then return end
	local a = v:GetAccessRights()
	if ((a ~= constAccessRead) and (a ~= constAccessReadWrite)) then return end
	local val = v:GetValue()
	if (nil ~= val) then v:SetValue( val, constResponseFromCache ) end
end

function OnValueChange( oVarPath, strValue )
	local v = oVarPath:_getLeaf()
	if (nil == v) then return end
	local a = v:GetAccessRights()
	if ((a ~= constAccessReadWrite) and (a ~= constAccessWrite)) then return end

	local name = v:GetScriptName()

	if (name == "REFRESH") then
		if (tostring(strValue) == "1") then
			g_bForceRefresh = true
		end
		v:SetValue( "0", constValueChange )   -- Taster-Datenpunkt sofort zuruecksetzen
	elseif ((name == "COUNTRY") or (name == "SURCHARGE_CT") or (name == "VAT_PERCENT") or (name == "WINDOW_HOURS")) then
		g_bForceRefresh = true                -- Konfiguration geaendert -> neu abrufen/umrechnen
	elseif (name == "THRESHOLD_CT") then
		refreshCurrentFromCache()             -- nur IS_CHEAP neu bewerten, kein neuer Abruf noetig
	end
end
