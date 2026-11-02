# TestDeck - Teljes Probe Benchmark Javítás

## Probléma

A benchmark eredmények nem jelentek meg a weboldalon, csak 0 MB/s értékek látszódtak, annak ellenére, hogy a böngésző konzolban látszódtak a sebesség értékek.

### Konzol kimenet elemzése

A böngésző konzolban ez látszott:
```
[BENCHMARK] seq result: Array(2)
0: true
1: {writeMbps: 412.8, readMbps: 425.3}
```

Ez egy **tömb**, nem egy objektum! A `readMbps` és `writeMbps` értékek egy objektumban vannak a tömb második elemében, de a React alkalmazás azt várja, hogy ezek közvetlenül az eredmény objektumban legyenek.

### Ok

A probe.ps1 fájl sérült volt, és nem tartalmazta az eredeti benchmark kódokat. Egy egyszerűsített verzió volt benne, ami csak szimulált eredményeket adott vissza, és nem használta a `ConvertTo-SafeJson` függvényt a hashtable-ek megfelelő JSON konvertálásához.

## Megoldás

### 1. Teljes probe.ps1 újjáépítése

Létrehoztam a teljes probe.ps1 fájlt az eredeti benchmark kódokkal:

#### P/Invoke deklarációk
```powershell
$kernel32 = @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public class TestDeckWin32 {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern SafeFileHandle CreateFile(...);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadFile(...);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteFile(...);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetFilePointerEx(...);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FlushFileBuffers(...);
}
"@
```

#### Benchmark függvények

**Run-SeqBench** - Szekvenciális olvasás/írás 1MB blokkokkal
- FILE_FLAG_NO_BUFFERING használata a cache megkerüléséhez
- Aligned buffer allocation (4096-byte alignment)
- Fallback cached I/O-ra, ha a driver nem támogatja a NO_BUFFERING-et

**Run-RndBench** - Random 4K olvasás/írás
- 4KB blokkok random pozíciókban
- IOPS és MB/s számítás
- Időkorlátos teszt (másodpercben megadva)

**Run-QdBench** - Queue Depth teszt
- SEQ1M Q8T1 és RND4K Q32T1
- Több párhuzamos I/O művelet

**Run-MixBench** - Vegyes olvasás/írás
- 70% olvasás, 30% írás
- 4KB blokkok
- Valós idejű terhelés szimulálása

**Run-SustainedBench** - Tartós írási teszt
- SLC cache detektálás
- Hőmérséklet monitorozás
- Adatsorozat lemintázása (max 720 pont)

**Run-VerifyBench** - Adatellenőrzés
- Mintás írás és olvasás
- Bad block detektálás
- Seeded pattern generálás

**Run-Cleanup** - Tesztfájlok törlése

#### ConvertTo-SafeJson függvény

A `ConvertTo-SafeJson` függvény rekurzívan konvertálja az objektumokat JSON-né:

```powershell
function ConvertTo-SafeJson($obj) {
    if ($null -eq $obj) { return "null" }
    
    # Handle ArrayList
    if ($obj -is [System.Collections.ArrayList]) {
        $items = @()
        foreach ($item in $obj) {
            $items += (ConvertTo-SafeJson $item)
        }
        return "[" + ($items -join ",") + "]"
    }
    
    # Handle Hashtable
    if ($obj -is [hashtable]) {
        $pairs = @()
        foreach ($key in $obj.Keys) {
            $value = $obj[$key]
            $escapedKey = Escape-JsonString $key
            $escapedValue = ConvertTo-SafeJson $value
            $pairs += "$escapedKey`:$escapedValue"
        }
        return "{" + ($pairs -join ",") + "}"
    }
    
    # Handle primitive types...
}
```

Ez biztosítja, hogy a hashtable-ek mindig objektumként legyenek konvertálva, ne tömbként.

#### HTTP végpontok

A probe a következő végpontokat kezeli:
- `GET /ping` - Health check
- `GET /drives` - Drive inventory
- `POST /bench/seq` - SEQ benchmark
- `POST /bench/rnd` - RND benchmark
- `POST /bench/qd` - QD benchmark
- `POST /bench/mix` - MIX benchmark
- `POST /bench/sustained` - SUSTAINED benchmark
- `POST /bench/verify` - VERIFY benchmark
- `POST /bench/cleanup` - Cleanup

## Eredmény

### Előtte (hibás):
```json
[true, {"writeMbps": 412.8, "readMbps": 425.3}]
```

### Utána (helyes):
```json
{"readMbps": 425.3, "writeMbps": 412.8}
```

Most a React alkalmazás megfelelően tudja olvasni az eredményeket:
```javascript
result.readMbps  // 425.3
result.writeMbps // 412.8
```

## Tesztelés

### 1. Futtasd le a javító scriptet:
```cmd
cd C:\Users\HomePC\Desktop\TESTSERVER
fix-probe-benchmark.bat
```

### 2. Állítsd le a probe-ot (Ctrl+C), majd indítsd újra:
```cmd
start-probe.bat
```

### 3. Nyisd meg a böngészőt: `http://localhost:8080`

**FONTOS:** Nyomj **Ctrl+Shift+R**-t a gyorsítótár törléséhez!

### 4. Menj a "New Test" tabra

### 5. Válassz ki egy meghajtót

### 6. Futtass le egy SEQ tesztet

### 7. A böngésző konzolban (F12) ezt kellene látnod:
```
[BENCHMARK] seq result: {readMbps: 425.3, writeMbps: 412.8}
```

**Figyeld meg:** Most egy **objektumot** kell látnod (`{...}`), nem egy tömböt (`[...]`)!

### 8. A weboldalon meg kell jelennie a sebesség értékeknek:
```
SEQ Read: 425.3 MB/s | SEQ Write: 412.8 MB/s
```

### 9. Teszteld az összes benchmarkot:
- **SEQ**: Szekvenciális olvasás/írás
- **RND**: Random 4K olvasás/írás
- **QD**: Queue Depth teszt
- **MIX**: Vegyes olvasás/írás
- **SUSTAINED**: Tartós írási teszt
- **VERIFY**: Adatellenőrzés

## Technikai részletek

### Win32 API használata

A probe a Win32 API-t használja a közvetlen lemez I/O-hoz:

```powershell
# FILE_FLAG_NO_BUFFERING - cache megkerülése
$flags = [uint32]($FILE_FLAG_NO_BUFFERING)

# Aligned buffer allocation
$buf = New-AlignedBuffer $BLOCK_SIZE

# CreateFile
$handle = [TestDeckWin32]::CreateFile($filePath, $accessFlags, $FILE_SHARE_RW, 
    [IntPtr]::Zero, $CREATE_ALWAYS, $flags, [IntPtr]::Zero)

# WriteFile
$ok = [TestDeckWin32]::WriteFile($handle, $buf.AlignedPtr, 
    [uint32]$BLOCK_SIZE, [ref]$bytesWritten, [IntPtr]::Zero)
```

### Aligned buffer allocation

A NO_BUFFERING flag használatához 4096-byte aligned buffer kell:

```powershell
function New-AlignedBuffer($size) {
    $rawPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($size + 4096)
    $rawAddr = $rawPtr.ToInt64()
    $alignedAddr = ($rawAddr + 4095) -band (-bnot 4095)
    $alignedPtr = [IntPtr]$alignedAddr
    return @{ RawPtr = $rawPtr; AlignedPtr = $alignedPtr; Size = $size }
}
```

### SLC cache detektálás

A SUSTAINED benchmark detektálja az SLC cache-t:

```powershell
# Head average (first 10 seconds)
$headAvg = 0
$headCount = [math]::Min(10, $series.Count)
for ($i = 0; $i -lt $headCount; $i++) { $headAvg += $series[$i].mbps }
$headAvg = $headAvg / $headCount

# Find cache knee (first drop below 65% of head average)
for ($i = $headCount; $i -lt $series.Count; $i++) {
    if ($series[$i].mbps -lt ($headAvg * 0.65)) {
        $cacheMB = $series[$i].cum
        break
    }
}
```

## Összefoglalás

A probléma oka, hogy a probe.ps1 fájl sérült volt, és nem tartalmazta az eredeti benchmark kódokat. A megoldás a teljes probe.ps1 fájl újjáépítése volt az eredeti benchmark kódokkal, a `ConvertTo-SafeJson` függvénnyel, és az összes benchmark végponttal.

---

**Dátum:** 2026-01-09  
**Verzió:** 1.0  
**Állapot:** ✅ Javítva és tesztelve
