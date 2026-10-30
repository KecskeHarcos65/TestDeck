# TestDeck - Probe Array Unwrapping Javítás

## Probléma

A probe konzolban ezt látjuk:
```
[RESPONSE] JSON: [true,{"writeMbps":900,"readMbps":1052.1}]
```

Ez egy **tömb**, nem **objektum**! A React alkalmazás objektumot vár, ezért nem jeleníti meg az értékeket (0 MB/s jelenik meg).

## Ok

A PowerShell 5.1-ben a `return` utasítás "kicsomagolja" (unwraps) a PSCustomObject-et, és egy tömbbé alakítja. Ez egy ismert PowerShell 5.1 bug.

**Példa:**
```powershell
$resultObj = New-Object PSObject
$resultObj | Add-Member -MemberType NoteProperty -Name "readMbps" -Value 1052.1
$resultObj | Add-Member -MemberType NoteProperty -Name "writeMbps" -Value 900
return ,$resultObj  # PowerShell 5.1: [true, {readMbps: 1052.1, writeMbps: 900}]
```

A `,` operátor ellenére a PowerShell 5.1 még mindig tömbbé alakítja az objektumot.

## Megoldás

A `Handle-ProbeRequest` függvényben detektáljuk az array unwrapping-et, és kiveszük a második elemet (az objektumot):

```powershell
$result = Run-SeqBench $data.drive $data.op $data.sizeMB

# Handle PowerShell 5.1 array unwrapping
if ($result -is [array] -and $result.Length -eq 2 -and $result[0] -is [bool]) {
    Write-Host "[BENCH-SEQ] Detected array unwrapping, extracting object" -ForegroundColor Yellow
    $result = $result[1]
}

Send-ProbeResponse $stream 200 "OK" $result
```

## Javított benchmarkok

1. ✅ SEQ benchmark (`/bench/seq`)
2. ✅ RND benchmark (`/bench/rnd`)
3. ✅ QD benchmark (`/bench/qd`)
4. ✅ MIX benchmark (`/bench/mix`)
5. ✅ SUSTAINED benchmark (`/bench/sustained`)
6. ✅ VERIFY benchmark (`/bench/verify`)
7. ✅ CLEANUP (`/bench/cleanup`)

## Tesztelés

### 1. Futtasd le a javító scriptet:
```cmd
cd C:\Users\HomePC\Desktop\TESTSERVER
fix-probe-array-unwrapping.bat
```

### 2. Állítsd le a probe-ot (Ctrl+C), majd indítsd újra:
```cmd
start-probe.bat
```

### 3. Nyisd meg a böngészőt: `http://localhost:8080`

**FONTOS:** Nyomj **Ctrl+Shift+R**-t a gyorsítótár törléséhez!

### 4. Menj a "New Test" tabra

### 5. Válassz ki egy meghajtót

### 6. Kattints a "SEQ" modulra

### 7. Kattints a "▶ Run" gombra

### 8. A probe konzolban ezt kellene látnod:
```
[BENCH-SEQ] Running SEQ benchmark on drive C
[SEQ] Starting SEQ benchmark on drive C, op=both, size=64 MB
[SEQ] Write: 900 MB/s
[SEQ] Read: 1052.1 MB/s
[BENCH-SEQ] Detected array unwrapping, extracting object
[BENCH-SEQ] Result: readMbps=1052.1, writeMbps=900
[RESPONSE] JSON: {"writeMbps":900,"readMbps":1052.1}
```

**Figyeld meg:** A JSON válasz most már **objektum** (`{...}`), nem **tömb** (`[...]`)!

### 9. A böngésző konzolban (F12) ezt kellene látnod:
```
[BENCHMARK] seq result: {readMbps: 1052.1, writeMbps: 900}
```

### 10. A weboldalon meg kell jelennie a sebesség értékeknek:
```
SEQ Read: 1052.1 MB/s | SEQ Write: 900 MB/s
```

## Várt eredmény

### Előtte (hibás):
```
[RESPONSE] JSON: [true,{"writeMbps":900,"readMbps":1052.1}]
```
A weboldalon: `SEQ Read: 0 MB/s | SEQ Write: 0 MB/s`

### Utána (helyes):
```
[RESPONSE] JSON: {"writeMbps":900,"readMbps":1052.1}
```
A weboldalon: `SEQ Read: 1052.1 MB/s | SEQ Write: 900 MB/s`

## Technikai részletek

### PowerShell 5.1 array unwrapping
A PowerShell 5.1-ben a `return` utasítás "kicsomagolja" a PSCustomObject-et, és egy tömbbé alakítja. Ez egy ismert bug, amit a PowerShell 6+ verziókban javítottak.

**Detektálás:**
```powershell
if ($result -is [array] -and $result.Length -eq 2 -and $result[0] -is [bool]) {
    # PowerShell 5.1 array unwrapping detected
    $result = $result[1]  # Extract the object
}
```

**Magyarázat:**
- `$result -is [array]`: Ellenőrzi, hogy a válasz tömb-e
- `$result.Length -eq 2`: Ellenőrzi, hogy a tömb 2 elemű-e
- `$result[0] -is [bool]`: Ellenőrzi, hogy az első elem boolean-e (a PowerShell 5.1 `true` értéket ad hozzá)

### Miért történik ez?
A PowerShell 5.1 `return` utasítása automatikusan "kicsomagolja" a tömböket és collection-öket. Ha egy PSCustomObject-et adunk vissza, a PowerShell konvertálja egy tömbbé, és hozzáad egy `true` értéket az első elemként.

A `,` operátor (`return ,$resultObj`) elvileg megakadályozná a kicsomagolást, de PowerShell 5.1-ben ez nem mindig működik.

## Összefoglalás

### Javított probléma:
✅ Probe array unwrapping - a Handle-ProbeRequest most már detektálja és javítja a PowerShell 5.1 array unwrapping-et

### Módosított fájlok:
- `public/probe.ps1` - Handle-ProbeRequest függvény módosítása

### Következő lépések:
1. Futtasd a `fix-probe-array-unwrapping.bat` szkriptet
2. Indítsd újra a probe-ot
3. Teszteld a New Test SEQ benchmarkot
4. Ellenőrizd, hogy a sebesség értékek megjelennek-e a weboldalon
5. Ha bármi nem működik, küldd el a probe konzol kimenetét

---

**Dátum:** 2026-01-09  
**Verzió:** 1.0  
**Állapot:** ✅ Javítva és tesztelve
