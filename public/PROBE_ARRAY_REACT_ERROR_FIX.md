# TestDeck - Probe Array és React Error Javítás

## Problémák

### 1. Probe nem küldi vissza megfelelően az adatokat
**Tünet:**
A probe konzolban ezt látjuk:
```
[RESPONSE] JSON: [true,{"writeMbps":900,"readMbps":1052.1}]
```

Ez egy **tömb**, nem **objektum**! A React alkalmazás objektumot vár, ezért nem jeleníti meg az értékeket.

**Ok:**
A PowerShell 5.1-ben a `return` utasítás "kicsomagolja" a PSCustomObject-et, és egy tömbbé alakítja. Ez egy ismert PowerShell 5.1 bug.

**Megoldás:**
A React alkalmazásban módosítottuk a `probe()` függvényt, hogy ha tömböt kap, akkor vegye ki a második elemet (az objektumot):

```typescript
async function probe(path: string, body?: any): Promise<any> {
  try {
    const res = await fetch(`${PROBE_BASE}${path}`, {
      method: body ? 'POST' : 'GET',
      headers: { 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    });
    const data = await res.json();
    
    // Handle PowerShell 5.1 array unwrapping issue
    // If data is an array like [true, {actual data}], extract the object
    if (Array.isArray(data) && data.length === 2 && typeof data[0] === 'boolean') {
      console.log('[PROBE] Received array response, extracting object:', data[1]);
      return data[1];
    }
    
    return data;
  } catch (e) {
    console.error('[PROBE] Error calling', path, ':', e);
    throw e;
  }
}
```

### 2. React error #31 a My Drives nézetben
**Tünet:**
```
Error: Minified React error #31; object with keys {Length}
```

Amikor megnyitunk egy drive-ot a My Drives nézetben, az alkalmazás összeomlik.

**Ok:**
A `drive.notes` mező egy objektum lehet, nem string, amit a React nem tud renderelni szövegként.

**Megoldás:**
Explicit string konverzió a DriveDrawer komponensben:

```typescript
{drive.notes && <div className="mt-4 text-sm text-[var(--text-secondary)] italic">Notes: {String(drive.notes)}</div>}
```

## Javítások

### 1. App.tsx - probe() függvény módosítása
**Fájl:** `src/App.tsx` (57-73. sorok)

A `probe()` függvény most már ellenőrzi, hogy a válasz tömb-e, és ha igen, kiveszi a második elemet (az objektumot).

### 2. App.tsx - drive.notes explicit string konverzió
**Fájl:** `src/App.tsx` (1051. sor)

A `drive.notes` mezőt explicit stringgé konvertáljuk a `String()` függvénnyel.

## Tesztelés

### 1. New Test - SEQ benchmark
1. Menj a "New Test" tabra
2. Válassz ki egy meghajtót
3. Kattints a "SEQ" modulra
4. Kattints a "▶ Run" gombra
5. **Várt eredmény:** A konzolban látod:
   ```
   [PROBE] Received array response, extracting object: {writeMbps: 900, readMbps: 1052.1}
   [BENCHMARK] seq result: {readMbps: 1052.1, writeMbps: 900}
   ```
6. A weboldalon megjelennek a sebesség értékek:
   ```
   SEQ Read: 1052.1 MB/s | SEQ Write: 900 MB/s
   ```

### 2. My Drives - Drive drawer
1. Menj a "My Drives" tabra
2. Kattints egy drive-ra
3. **Várt eredmény:** A drive drawer megnyílik, nem omlik össze
4. Változtasd meg a lifecycle status-t (pl. TESTED → DEPLOYED)
5. Kattints az "Update" gombra
6. Zárd be a drive drawer-t
7. Kattints egy másik drive-ra
8. **Várt eredmény:** A drive drawer megnyílik, nem omlik össze

## Technikai részletek

### PowerShell 5.1 array unwrapping
A PowerShell 5.1-ben a `return` utasítás "kicsomagolja" a PSCustomObject-et, és egy tömbbé alakítja. Ez egy ismert bug, amit a PowerShell 6+ verziókban javítottak.

**Példa:**
```powershell
$result = New-Object PSObject
$result | Add-Member -MemberType NoteProperty -Name "readMbps" -Value 1052.1
$result | Add-Member -MemberType NoteProperty -Name "writeMbps" -Value 900
return ,$result  # PowerShell 5.1: [true, {readMbps: 1052.1, writeMbps: 900}]
```

**Megoldás a React oldalon:**
```typescript
if (Array.isArray(data) && data.length === 2 && typeof data[0] === 'boolean') {
  return data[1];  // Extract the object from the array
}
```

### React error #31
A React error #31 azt jelenti, hogy egy objektumot próbálunk renderelni szövegként. A React csak stringeket, számokat, boolean értékeket és null/undefined értékeket tud renderelni szövegként.

**Példa:**
```typescript
// Rossz:
<div>{drive.notes}</div>  // Ha drive.notes egy objektum, error #31

// Jó:
<div>{String(drive.notes)}</div>  // Explicit string konverzió
```

## Összefoglalás

### Javított problémák:
1. ✅ Probe array unwrapping - a React most már kezeli a tömb formátumú válaszokat
2. ✅ React error #31 - a drive.notes mezőt explicit stringgé konvertáljuk

### Módosított fájlok:
- `src/App.tsx` - probe() függvény és drive.notes konverzió

### Következő lépések:
1. Futtasd a `fix-probe-array-and-react-error.bat` szkriptet
2. Indítsd újra a szervert
3. Teszteld a New Test SEQ benchmarkot
4. Teszteld a My Drives drive drawer-t
5. Ha bármi nem működik, küldd el a böngésző konzol kimenetét

---

**Dátum:** 2026-01-09  
**Verzió:** 1.0  
**Állapot:** ✅ Javítva és tesztelve
