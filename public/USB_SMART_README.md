# USB SSD S.M.A.R.T. adatok kiolvasása

## Probléma
USB-n keresztül csatlakoztatott SSD-k esetén a S.M.A.R.T. adatok (wear level, hőmérséklet, health status) nem érhetők el a PowerShell `Get-StorageReliabilityCounter` parancsával.

## Megoldás: smartmontools telepítése

A **smartmontools** egy ingyenes, nyílt forráskódú eszköz, amely közvetlenül a SCSI/ATA pass-through parancsokat használja USB-n keresztül is.

### Telepítés Windows-on

#### 1. letöltés
Látogass el a smartmontools hivatalos oldalára:
- https://www.smartmontools.org/wiki/Download#InstalltheWindowsbinarypackages

Vagy közvetlen letöltés:
- https://sourceforge.net/projects/smartmontools/files/smartmontools/

#### 2. Telepítés
1. Töltsd le a legújabb `.exe` telepítőt (pl. `smartmontools-7.4-1.win32-setup.exe`)
2. Futtasd a telepítőt
3. Telepítési útvonal: `C:\Program Files\smartmontools\` (alapértelmezett)
4. **Fontos:** A telepítés után a `smartctl.exe` elérhető lesz a `bin` mappában

#### 3. Ellenőrzés
Nyiss egy PowerShell ablakot és futtasd:
```powershell
& "C:\Program Files\smartmontools\bin\smartctl.exe" --version
```

Ha sikeres, látnod kell a verziószámot.

### Használat

#### USB SSD S.M.A.R.T. adatainak lekérdezése
```powershell
# Eszköz lista
& "C:\Program Files\smartmontools\bin\smartctl.exe" --scan

# Konkrét eszköz S.M.A.R.T. adatai (pl. PhysicalDrive1)
& "C:\Program Files\smartmontools\bin\smartctl.exe" -A \\.\PhysicalDrive1

# Teljes információ
& "C:\Program Files\smartmontools\bin\smartctl.exe" -a \\.\PhysicalDrive1
```

### Probe automatikus smartctl használata

A probe automatikusan megpróbálja használni a `smartctl.exe`-t, ha telepítve van. A következő útvonalakat keresi:
1. `C:\Program Files\smartmontools\bin\smartctl.exe`
2. `C:\Program Files (x86)\smartmontools\bin\smartctl.exe`
3. `smartctl.exe` (PATH-ban)

### Amit kiolvashat smartctl-lel USB-n keresztül

✅ **Elérhető adatok:**
- Modellnév
- Sorozatszám
- Firmware verzió
- Kapacitás
- Hőmérséklet (Temperature)
- SSD élettartam / wear level (SSD Life Left / Media Wearout Indicator)
- Power-on hours (üzemórák száma)
- Power cycle count (bekapcsolások száma)
- Reallocated sectors (áthelyezett szektorok)
- Current pending sectors (függőben lévő szektorok)
- Offline uncorrectable (offline nem javítható hibák)

❌ **Nem elérhető adatok:**
- Néhány vendor-specifikus attribútum
- Néhány fejlett diagnosztikai adat

### USB enclosure kompatibilitás

A smartmontools a legtöbb USB enclosure-rel működik, de néhány régebbi vagy olcsóbb eszköz nem támogatja a pass-through parancsokat.

**Tesztelt enclosure-ek:**
- ✅ ORICO USB 3.1 NVMe enclosure
- ✅ Sabrent USB 3.2 NVMe enclosure
- ✅ Ugreen USB-C NVMe enclosure
- ✅ ASMedia ASM2362 chip-alapú enclosure-ek
- ⚠️ Realtek RTL9210B (néha problémás)
- ❌ Néhány olcsó USB 3.0 SATA enclosure

### Alternatív megoldások

Ha a smartmontools nem működik:

1. **Közvetlen SATA/NVMe csatlakozás**
   - Csatlakoztassa az SSD-t közvetlenül az alaplapra
   - Ez a legmegbízhatóbb módszer

2. **Adminisztrátori jogok**
   - Néhány enclosure admin jogokat igényel a S.M.A.R.T. adatok olvasásához
   - Futtassa a probe-ot adminisztrátorként

3. **Gyártói szoftver**
   - Samsung SSD: Samsung Magician
   - WD SSD: Western Digital Dashboard
   - Crucial SSD: Crucial Storage Executive
   - Ezek a szoftverek néha USB-n keresztül is működnek

### Hibaelhárítás

#### smartctl nem találja az eszközt
```powershell
# Próbálja meg explicit eszköztípussal
& "C:\Program Files\smartmontools\bin\smartctl.exe" -d sat -A \\.\PhysicalDrive1
& "C:\Program Files\smartmontools\bin\smartctl.exe" -d nvme -A \\.\PhysicalDrive1
& "C:\Program Files\smartmontools\bin\smartctl.exe" -d scsi -A \\.\PhysicalDrive1
```

#### Access denied hiba
- Futtassa PowerShell-t adminisztrátorként
- Ellenőrizze, hogy az enclosure nem igényel-e speciális drivert

#### No such device hiba
- Ellenőrizze, hogy az eszköz csatlakoztatva van-e
- Próbálja meg másik USB portot
- Ellenőrizze az Eszközkezelőben, hogy az eszköz megjelenik-e

### Probe konzol kimenet értelmezése

#### Sikeres smartctl használat:
```
[INVENTORY] Found smartctl at: C:\Program Files\smartmontools\bin\smartctl.exe
[INVENTORY] Temperature from smartctl: 35°C
[INVENTORY] Wear from smartctl: 12%
[INVENTORY] S.M.A.R.T. data retrieved via smartctl
```

#### smartctl nem elérhető:
```
[INVENTORY] USB device: S.M.A.R.T. data not accessible. Install smartmontools: https://www.smartmontools.org/
```

#### smartctl telepítve, de nem működik:
```
[INVENTORY] Found smartctl at: C:\Program Files\smartmontools\bin\smartctl.exe
[INVENTORY] smartctl failed with exit code: 2
[INVENTORY] USB device: S.M.A.R.T. data not accessible. Install smartmontools: https://www.smartmontools.org/
```

### Összefoglalás

A USB-n keresztüli S.M.A.R.T. adatok kiolvasásához:
1. Telepítse a smartmontools-t
2. Indítsa újra a probe-ot
3. A probe automatikusan használja a smartctl-t
4. Ha nem működik, próbálja meg közvetlen SATA/NVMe csatlakozással
