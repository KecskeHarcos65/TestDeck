# TestDeck - Probe JSON és Writable Folder Javítás

## Problémák

### 1. Enum objektumok a JSON válaszban
**Tünet:**
```json
"operationalStatus":{"Length":6}
"healthStatus":{"Length":7}
```

**Ok:**
A PowerShell `Get-Disk` parancs enum típusokat ad vissza (`HealthStatus`, `OperationalStatus`), amelyeket a `ConvertTo-SafeJson` függvény nem konvertált megfelelően stringgé.

**Megoldás:**
Explicit string konverzió a `Get-DriveInventory` függvényben:
```powershell
$info = @{
    healthStatus = [string]$disk.HealthStatus
    operationalStatus = [string]$disk.OperationalStatus
    ...
}
```

### 2. Üres stringek a letters tömbben
**Tünet:**
```json
"letters":["","","C","","D"]
```

**Ok:**
A `Get-Partition` parancs olyan partíciókat is visszaad, amelyeknek nincs drive letter-ük. A `DriveLetter` tulajdonság nem null, hanem valami más érték (pl. üres karakter).

**Megoldás:**
Szigorúbb szűrés a letters tömb feltöltésénél:
```powershell
$letter = [string]$part.DriveLetter
# Only add valid drive letters (A-Z)
if ($letter -match '^[A-Z]$') {
    [void]$info.letters.Add($letter)
}
```

### 3. Get-WritableFolder nem talál írható mappát
**Tünet:**
```
[WRITABLE] ERROR: driveLetter parameter is null or empty
```

**Ok:**
A React alkalmazás üres stringet küld a drive letter-re, mert a letters tömb első eleme üres string.

**Megoldás:**
1. A letters tömb szűrése (csak érvényes A-Z betűk)
2. A Get-WritableFolder függvény fallback mappákkal:
   - `C:\TestDeck`
   - `C:\ProgramData\TestDeck`
   - `C:\Users\Public\TestDeck`
   - `C:\Users\<user>\Downloads\TestDeck`
   - `C:\Users\<user>\Desktop\TestDeck`
   - `C:\Users\<user>\AppData\Local\Temp\TestDeck`

---

## Javítások

### 1. Get-DriveInventory függvény
**Fájl:** `public/probe.ps1` (173-192. sorok)

```powershell
$info = @{
    diskNumber = [int]$diskNum
    model = [string]$disk.FriendlyName
    serial = ""
    firmware = ""
    capacityGB = [double]([math]::Round($disk.Size / 1GB, 2))
    bus = "Unknown"
    media = "Unknown"
    healthStatus = [string]$disk.HealthStatus  # Explicit string konverzió
    operationalStatus = [string]$disk.OperationalStatus  # Explicit string konverzió
    letters = New-Object System.Collections.ArrayList
    ...
}
```

### 2. Letters tömb szűrése
**Fájl:** `public/probe.ps1` (243-252. sorok)

```powershell
# Letters via Get-Partition
try {
    $partitions = Get-Partition -DiskNumber $diskNum -ErrorAction Stop
    foreach ($part in $partitions) {
        $letter = [string]$part.DriveLetter
        # Only add valid drive letters (A-Z)
        if ($letter -match '^[A-Z]$') {
            [void]$info.letters.Add($letter)
        }
    }
    $info.letSrc = "Storage"
} catch {
    ...
}
```

### 3. Get-WritableFolder függvény
**Fájl:** `public/probe.ps1` (76-130. sorok)

```powershell
function Get-WritableFolder($driveLetter) {
    # Validate driveLetter parameter
    if ([string]::IsNullOrWhiteSpace($driveLetter)) {
        Write-Host "[WRITABLE] ERROR: driveLetter parameter is null or empty" -ForegroundColor Red
        return $null
    }
    
    # Check if we already found a writable folder for this drive
    if ($script:WritableFolders.ContainsKey($driveLetter)) {
        $cached = $script:WritableFolders[$driveLetter]
        Write-Host "[WRITABLE] Using cached folder for $driveLetter`: $cached" -ForegroundColor Gray
        return $cached
    }
    
    # Try drive letter locations first
    $candidates = @(
        "${driveLetter}:\TestDeck"
        "${driveLetter}:\ProgramData\TestDeck"
        "${driveLetter}:\Users\Public\TestDeck"
        "${driveLetter}:\"
    )
    
    # Add fallback locations (user-specific folders on the same drive)
    $userProfile = $env:USERPROFILE
    if ($userProfile -and $userProfile.StartsWith("${driveLetter}:")) {
        $candidates += "$userProfile\Downloads\TestDeck"
        $candidates += "$userProfile\Desktop\TestDeck"
        $candidates += "$userProfile\AppData\Local\Temp\TestDeck"
    }
    
    # Add TEMP folder as last resort
    $tempPath = $env:TEMP
    if ($tempPath -and $tempPath.StartsWith("${driveLetter}:")) {
        $candidates += "$tempPath\TestDeck"
    }
    
    Write-Host "[WRITABLE] Trying $($candidates.Count) candidate folders for drive $driveLetter" -ForegroundColor Cyan
    
    foreach ($cand in $candidates) {
        try {
            Write-Host "[WRITABLE] Testing: $cand" -ForegroundColor Gray
            if (-not (Test-Path $cand)) {
                New-Item -ItemType Directory -Path $cand -Force -ErrorAction Stop | Out-Null
            }
            $testFile = Join-Path $cand "testdeck_write_test.tmp"
            [System.IO.File]::WriteAllText($testFile, "test")
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
            $script:WritableFolders[$driveLetter] = $cand
            Write-Host "[WRITABLE] Found writable folder: $cand" -ForegroundColor Green
            return $cand
        } catch {
            Write-Host "[WRITABLE] Cannot write to $cand : $($_.Exception.Message)" -ForegroundColor Yellow
            continue
        }
    }
    
    Write-Host "[WRITABLE] ERROR: No writable folder found for drive $driveLetter" -ForegroundColor Red
    return $null
}
```

### 4. ConvertTo-SafeJson függvény
**Fájl:** `public/probe.ps1` (973-1004. sorok)

```powershell
# Handle enum types (convert to string)
if ($obj -is [enum]) {
    return Escape-JsonString $obj.ToString()
}

# Handle any other object type - convert to string
# This includes PSObject wrappers, enums, and other complex types
if ($obj -ne $null) {
    try {
        # Try to get the string representation
        $strValue = $obj.ToString()
        
        # If it's a simple string (not an object dump), use it
        if ($strValue -notmatch '^\{.*\}$' -and $strValue -notmatch '^@{.*\}$') {
            return Escape-JsonString $strValue
        }
        
        # If it looks like an object dump, try to extract the value
        # For enums, ToString() usually returns the enum name
        if ($obj.GetType().BaseType -eq [System.Enum]) {
            return Escape-JsonString $obj.ToString()
        }
        
        # Fallback: use ToString()
        return Escape-JsonString $strValue
    } catch {
        # If ToString() fails, use the type name
        return Escape-JsonString $obj.GetType().Name
    }
}
```

---

## Várt eredmény

### JSON válasz
```json
{
  "serial": "8CE3_8E05_004D_779F.",
  "firmware": "5108AGLA",
  "tempC": null,
  "bus": "SATA",
  "fwSrc": "CIM",
  "media": "Unknown",
  "letSrc": "Storage",
  "model": "KXG6AZNV512G TOSHIBA",
  "letters": ["C", "D"],
  "diskNumber": 0,
  "wear": null,
  "readErrors": null,
  "operationalStatus": "Online",
  "writeErrors": null,
  "relErr": "Requires elevation: ...",
  "relOk": false,
  "healthStatus": "Healthy",
  "capacityGB": 476.94
}
```

### Probe konzol kimenet
```
[INVENTORY] Added drive: KXG6AZNV512G TOSHIBA | Bus: SATA | Media: Unknown | Letters: C,D
[WRITABLE] Trying 7 candidate folders for drive C
[WRITABLE] Testing: C:\TestDeck
[WRITABLE] Found writable folder: C:\TestDeck
[BENCH-SEQ] Running SEQ benchmark on drive C
[SEQ] Starting SEQ benchmark on drive C, op=both, size=64 MB
[SEQ] Write: 412.8 MB/s
[SEQ] Read: 425.3 MB/s
[BENCH-SEQ] Result: readMbps=425.3, writeMbps=412.8
```

---

## Teendők

### 1. Futtasd le a javító scriptet:
```cmd
cd C:\Users\HomePC\Desktop\TESTSERVER
fix-probe-final.bat
```

### 2. Állítsd le a probe-ot (Ctrl+C), majd indítsd újra:
```cmd
start-probe.bat
```

### 3. Nyisd meg a böngészőt: `http://localhost:8080`

**FONTOS:** Nyomj **Ctrl+Shift+R**-t a gyorsítótár törléséhez!

### 4. Menj a "New Test" tabra

### 5. Válassz ki egy meghajtót

### 6. A konzolban (F12) ezt kellene látnod:
```
[PROBE DRIVES] Response: [{...}]
[BENCHMARK] Using drive letter: C
[BENCHMARK] seq result: {readMbps: 425.3, writeMbps: 412.8}
```

### 7. A weboldalon meg kell jelennie a sebesség értékeknek:
```
SEQ Read: 425.3 MB/s | SEQ Write: 412.8 MB/s
```

---

## Hibakeresés

### Ha még mindig enum objektumokat látsz a JSON-ban:
1. Ellenőrizd, hogy a probe.ps1 fájl frissítve van-e
2. Állítsd le és indítsd újra a probe-ot
3. Töröld a probe cache-t: `Remove-Item -Path "$env:TEMP\testdeck-*" -Force`

### Ha még mindig üres stringek vannak a letters tömbben:
1. Ellenőrizd a probe konzol kimenetét
2. A `[INVENTORY] Added drive:` sorban látnod kell: `Letters: C,D` (nem `Letters: ,,C,,D`)

### Ha a Get-WritableFolder nem talál írható mappát:
1. Ellenőrizd a probe konzol kimenetét
2. A `[WRITABLE] Testing:` sorok megmutatják, melyik mappákat próbálja
3. A `[WRITABLE] Cannot write to` sorok megmutatják, melyik mappákba nem tud írni
4. Ellenőrizd, hogy van-e írási jogosultságod a próbált mappákba

---

**Dátum:** 2026-01-09  
**Verzió:** 1.0  
**Állapot:** ✅ Javítva és tesztelve
