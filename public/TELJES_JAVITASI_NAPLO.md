# TestDeck - Teljes Javítási Napló

## Áttekintés

Ez a dokumentum tartalmazza az összes javítást, amit a TestDeck alkalmazáson végeztünk a fejlesztés során.

---

## 1. Socket Timeout Hiba Javítás

**Dátum:** 2026-01-09  
**Fájl:** `public/server.ps1`

### Probléma
A szerver konzolban a következő hiba jelent meg:
```
Exception setting "ReceiveTimeout": "Nem érhető el egy teljesített objektum.
Objektum neve: „System.Net.Sockets.Socket"."
```

### Ok
A `Parse-HttpRequest` függvényben a `$reader.Dispose()` bezárta a `NetworkStream`-et, ami bezárta a socketet is. Ezért amikor a szerver a `Handle-Request` hívás előtt megpróbálta beállítani a `ReceiveTimeout`-ot, a socket már le volt zárva.

### Megoldás
Eltávolítottuk a `$reader.Dispose()` hívásokat a `Parse-HttpRequest` függvényből. A reader automatikusan felszabadul, amikor a függvény véget ér.

---

## 2. Favicon.ico 401 Hiba Javítás

**Dátum:** 2026-01-09  
**Fájl:** `public/server.ps1`

### Probléma
A böngésző automatikusan lekéri a `favicon.ico` fájlt, de a szerver 401 Unauthorized hibát adott vissza.

### Megoldás
Hozzáadtunk egy speciális handler-t a `/favicon.ico` kéréshez, ami 204 No Content választ ad vissza.

---

## 3. Asset Fájlok 401 Hiba Javítás

**Dátum:** 2026-01-09  
**Fájl:** `public/server.ps1`

### Probléma
A `/assets/*` útvonalon lévő fájlok (JS, CSS) 401 Unauthorized hibát kaptak.

### Ok
A szerver nem találta az asset fájlokat, mert a `$Matches[1]` változó nem volt megfelelően beállítva.

### Megoldás
Módosítottuk az asset handler-t, hogy `$path.Substring(8)` használatával kinyerje a fájlnevet.

---

## 4. React Infinite Loop Javítás

**Dátum:** 2026-01-09  
**Fájl:** `src/App.tsx`

### Probléma
A fő App komponensben lévő `useEffect` a `loadData` függvényt használta dependency-ként, ami infinite loop-ot okozott.

### Megoldás
Eltávolítottuk a `loadData` függvényt a dependency listából, és hozzáadtunk egy ESLint disable kommentet.

---

## 5. Login View Egyszerűsítés

**Dátum:** 2026-01-09  
**Fájl:** `src/App.tsx`

### Probléma
A login view eltűnt néhány másodperc után.

### Ok
A `setInterval` használata a boot log animációhoz problémákat okozott.

### Megoldás
Egyszerűsítettük a login view-t, hogy ne használjon `setInterval`-t. A boot log sorok most azonnal megjelennek animáció nélkül.

---

## 6. ArrayList Konverzió Javítás

**Dátum:** 2026-01-09  
**Fájl:** `public/server.ps1`

### Probléma
A `Read-JsonList` függvény nem ArrayList-et adott vissza, hanem fix méretű tömböt vagy PSCustomObject-et.

### Hibaüzenetek
- Labels: "A gyűjtemény rögzített méretű"
- Models: "A gyűjtemény rögzített méretű"
- Users: "PSCustomObject does not contain a method named 'Add'"

### Megoldás
Explicit ArrayList konverziót adtunk hozzá minden POST handler-ben:
```powershell
$labelsRaw = Read-JsonList $script:LabelsFile
$labels = New-Object System.Collections.ArrayList
foreach ($item in $labelsRaw) { [void]$labels.Add($item) }
```

---

## 7. Profiles "New Profile" Gomb Javítás

**Dátum:** 2026-01-09  
**Fájl:** `src/App.tsx`

### Probléma
A "+ New Profile" gombra kattintva nem jelent meg a szerkesztő űrlap.

### Ok
A feltétel `editing !== null || form.name !== ''` volt. A `startNew` függvény beállította:
- `editing` = null
- `form.name` = '' (üres string)

Tehát a feltétel: `false || false` = `false`, ezért nem jelent meg az űrlap.

### Megoldás
Hozzáadtunk egy külön `showForm` state-et, ami explicit jelzi, hogy meg kell-e jeleníteni az űrlapot.

---

## 8. Logout Gomb Javítás

**Dátum:** 2026-01-09  
**Fájl:** `src/App.tsx`

### Probléma
A logout gomb hover-alapú volt, ami azt jelentette, hogy amikor az egér elhagyta a gombot, a dropdown menu eltűnt.

### Megoldás
Click-alapú toggle-ot használtunk hover helyett. Hozzáadtunk egy `showUserMenu` state-et.

---

## 9. Session Crash Javítás

**Dátum:** 2026-01-09  
**Fájl:** `public/server.ps1`

### Probléma
Amikor több session volt az ArrayList-ben, a `ConvertTo-Json` nem mindig működött jól PowerShell 5.1-ben, ami miatt a második bejelentkezésnél crashelt az alkalmazás.

### Megoldás
Minden elemet külön konvertálunk JSON-né, majd összefűzzük őket egy tömbbé.

---

## 10. Probe Communication Fix

**Dátum:** 2026-01-09  
**Fájl:** `public/probe.ps1`

### Probléma
A probe 1 drive-ot talált, de 18-at adott vissza, és a `letters` mező furcsa formátumú volt (,,C,).

### Ok
A `Send-ProbeResponse` függvényben a `ConvertTo-Json` PowerShell 5.1-ben "kicsomagolja" az ArrayList-et.

### Megoldás
Explicit ArrayList kezelést adtunk hozzá a `Send-ProbeResponse` függvényhez.

---

## 11. Drive Detection Javítás

**Dátum:** 2026-01-09  
**Fájl:** `public/probe.ps1`

### Probléma
A probe nem talált meghajtókat.

### Megoldás
Részletes logolást adtunk hozzá a drive inventory-hoz, és javítottuk a `Get-DriveInventory` függvényt.

---

## 12. ContainsKey Hiba Javítás

**Dátum:** 2026-01-09  
**Fájl:** `public/probe.ps1`

### Probléma
A probe konzolban a következő hiba jelent meg:
```
Exception calling "ContainsKey" with "1" argument(s): "A kulcs nem lehet NULL."
```

### Ok
A `letters` tömb `[null, null, 'C', null]` formátumú volt, és a React az első elemet (`null`) használta drive betűként.

### Megoldás
1. A probe HTTP header feldolgozásnál nem adunk hozzá üres kulcsokat a headers hashtable-hez
2. A `Get-WritableFolder` függvény ellenőrzi a driveLetter paramétert
3. A React alkalmazás kiszűri a null/üres értékeket a letters tömbből

---

## 13. Benchmark Sebesség Értékek Javítás

**Dátum:** 2026-01-09  
**Fájl:** `public/probe.ps1`

### Probléma
A benchmark eredmények nem jelentek meg a weboldalon, csak 0 MB/s értékek látszódtak.

### Konzol kimenet
```
[BENCHMARK] seq result: Array(2)
0: true
1: {writeMbps: 412.8, readMbps: 425.3}
```

### Ok
A PowerShell 5.1 `ConvertTo-Json` parancsa néha **tömbbé konvertálja a hashtable-eket**, ahelyett hogy objektummá konvertálná őket.

### Megoldás
Hozzáadtunk egy `ConvertTo-SafeJson` segédfüggvényt, amely **PSCustomObject-é konvertálja a hashtable-eket** a JSON konverzió előtt.

---

## 14. JSON Hashtable Fix

**Dátum:** 2026-01-09  
**Fájl:** `public/probe.ps1`, `public/server.ps1`

### Probléma
A JSON válaszban a `healthStatus` és `operationalStatus` mezők még mindig enum objektumok voltak:
```json
"operationalStatus":{"Length":6}
"healthStatus":{"Length":7}
```

### Megoldás
Explicit string konverzió a `Get-DriveInventory` függvényben:
```powershell
healthStatus = [string]$disk.HealthStatus
operationalStatus = [string]$disk.OperationalStatus
```

---

## 15. Letters Tömb Szűrés

**Dátum:** 2026-01-09  
**Fájl:** `public/probe.ps1`

### Probléma
A `letters` tömb üres stringeket tartalmazott:
```json
"letters":["","","C","","D"]
```

### Megoldás
Szigorúbb szűrés a letters tömb feltöltésénél:
```powershell
$letter = [string]$part.DriveLetter
if ($letter -match '^[A-Z]$') {
    [void]$info.letters.Add($letter)
}
```

---

## 16. Get-WritableFolder Fallback Mappák

**Dátum:** 2026-01-09  
**Fájl:** `public/probe.ps1`

### Probléma
A `Get-WritableFolder` nem talált írható mappát.

### Megoldás
Fallback mappákat adtunk hozzá:
- `C:\TestDeck`
- `C:\ProgramData\TestDeck`
- `C:\Users\Public\TestDeck`
- `C:\Users\<user>\Downloads\TestDeck`
- `C:\Users\<user>\Desktop\TestDeck`
- `C:\Users\<user>\AppData\Local\Temp\TestDeck`

---

## 17. React Crash Javítás

**Dátum:** 2026-01-09  
**Fájl:** `src/App.tsx`

### Probléma
A React alkalmazás néha összeomlik, amikor egy drive adatait próbáljuk megnyitni.

### Hibaüzenet
```
Error: Minified React error #31; object with keys {Length}
```

### Ok
A szerver néha objektumot küldött a `healthStatus` és `operationalStatus` mezőkben.

### Megoldás
Minden mezőt explicit stringgé konvertáltunk a React oldalon:
```tsx
<div>{String(drive.healthStatus || 'Unknown')}</div>
```

---

## 18. Probe Array Unwrapping Javítás

**Dátum:** 2026-01-09  
**Fájl:** `public/probe.ps1`

### Probléma
A probe JSON válasz még mindig tömb formátumú:
```json
[true,{"writeMbps":1007.2,"readMbps":1102.5}]
```

### Ok
A PowerShell 5.1-ben a `return` utasítás "kicsomagolja" a PSCustomObject-et, és egy tömbbé alakítja.

### Megoldás
A `Handle-ProbeRequest` függvényben detektáljuk az array unwrapping-et, és kiveszük a második elemet:
```powershell
if ($result -is [array] -and $result.Length -eq 2 -and $result[0] -is [bool]) {
    Write-Host "[BENCH-SEQ] Detected array unwrapping, extracting object" -ForegroundColor Yellow
    $result = $result[1]
}
```

---

## 19. Lifecycle Status String Konverzió

**Dátum:** 2026-01-09  
**Fájl:** `src/App.tsx`

### Probléma
A DriveDrawer összeomlik lifecycle status váltás után.

### Megoldás
Explicit string konverzió:
```typescript
useEffect(() => {
  const lc = lifecycle.find(l => l.serial === drive.serial);
  if (lc) setLcStatus(String(lc.status || ''));
}, [drive, lifecycle]);
```

---

## 20. Probe Array Kezelés a React-ban

**Dátum:** 2026-01-09  
**Fájl:** `src/App.tsx`

### Probléma
A probe tömb formátumban küldi az adatokat, és a React nem jeleníti meg az értékeket.

### Megoldás
A `probe()` függvényben ellenőrizzük, hogy a válasz tömb-e, és ha igen, kiveszük a második elemet:
```typescript
if (Array.isArray(data) && data.length === 2 && typeof data[0] === 'boolean') {
  console.log('[PROBE] Received array response, extracting object:', data[1]);
  return data[1];
}
```

---

## Összefoglalás

### Javított problémák:
1. ✅ Socket timeout hiba
2. ✅ Favicon.ico 401 hiba
3. ✅ Asset fájlok 401 hiba
4. ✅ React infinite loop
5. ✅ Login view eltűnés
6. ✅ ArrayList konverzió
7. ✅ Profiles "New Profile" gomb
8. ✅ Logout gomb
9. ✅ Session crash
10. ✅ Probe communication
11. ✅ Drive detection
12. ✅ ContainsKey hiba
13. ✅ Benchmark sebesség értékek
14. ✅ JSON hashtable
15. ✅ Letters tömb szűrés
16. ✅ Get-WritableFolder fallback mappák
17. ✅ React crash
18. ✅ Probe array unwrapping
19. ✅ Lifecycle status string konverzió
20. ✅ Probe array kezelés a React-ban

### Módosított fájlok:
- `public/server.ps1` - Szerver oldal
- `public/probe.ps1` - Probe oldal
- `src/App.tsx` - React alkalmazás
- `src/index.css` - Stílusok
- `index.html` - HTML template

### Batch fájlok:
- `public/start-server.bat` - Szerver indítása
- `public/start-probe.bat` - Probe indítása
- `public/backup.bat` - Adatbázis backup
- `public/fix-*.bat` - Különböző javítások

### Dokumentáció:
- `public/*.md` - Részletes dokumentációk minden javításról

---

## Használat

### 1. Szerver indítása:
```cmd
cd C:\Users\HomePC\Desktop\TESTSERVER\public
start-server.bat
```

### 2. Probe indítása:
```cmd
cd C:\Users\HomePC\Desktop\TESTSERVER\public
start-probe.bat
```

### 3. Böngésző megnyitása:
```
http://localhost:8080
```

### 4. Bejelentkezés:
- Username: `admin`
- Password: A szerver indításakor kiírt jelszó

---

## Hibakeresés

### Ha a szerver nem indul:
1. Ellenőrizd, hogy a 8080 port nem foglalt-e
2. Nézd meg a szerver konzolt
3. Töröld a `data` mappát és indítsd újra

### Ha a probe nem indul:
1. Ellenőrizd, hogy a 8321 port nem foglalt-e
2. Nézd meg a probe konzolt
3. Futtasd adminisztrátorként

### Ha a weboldal nem töltődik be:
1. Nyomj Ctrl+Shift+R-t a gyorsítótár törléséhez
2. Ellenőrizd a böngésző konzolt (F12)
3. Ellenőrizd a szerver és probe konzolokat

### Ha a benchmark nem működik:
1. Ellenőrizd, hogy a probe fut-e
2. Nézd meg a probe konzolt
3. Ellenőrizd, hogy van-e írható mappa a meghajtón

---

**Dátum:** 2026-01-09  
**Verzió:** 1.0  
**Állapot:** ✅ Teljes mértékben működőképes
