# USB S.M.A.R.T. P/Invoke Implementáció

## ✅ Új funkció: S.M.A.R.T. adatok kiolvasása USB-n keresztül

A probe most már **közvetlenül olvassa ki a S.M.A.R.T. adatokat** USB-n keresztül P/Invoke használatával, **telepítés nélkül**!

## 🎯 Hogyan működik?

A probe a következő módszert használja:
1. **SCSI Pass-Through Direct** parancsok küldése az USB eszköznek
2. **ATA SMART** parancsok használata a S.M.A.R.T. adatok lekérdezésére
3. **DeviceIoControl** Win32 API hívások P/Invoke-on keresztül

Ez ugyanaz a módszer, amit a CrystalDiskInfo és más professzionális szoftverek használnak!

## 📊 Amit kiolvashat USB-n keresztül:

✅ **Elérhető adatok:**
- **Hőmérséklet** (Temperature) - Attribute 194 vagy 190
- **Wear Level** (Élettartam) - Attribute 232 vagy 233
- **Power-On Hours** (Üzemórák száma) - Attribute 9
- **Reallocated Sectors** (Áthelyezett szektorok) - Attribute 5
- **Modellnév** (CIM lekérdezésből)
- **Sorozatszám** (CIM lekérdezésből)
- **Firmware verzió** (CIM lekérdezésből)
- **Kapacitás**
- **Health Status** (Get-PhysicalDisk-ből)

## 🚀 Használat:

### 1. Indítsa el a probe-ot:
```cmd
start-probe.bat
```

### 2. Csatlakoztassa az USB SSD-t

### 3. Nézze meg a probe konzolt:
```
[INVENTORY] Attempting direct S.M.A.R.T. read via SCSI pass-through...
[SMART] Opening device: \\.\PhysicalDrive1
[SMART] Device opened successfully
[SMART] SMART data retrieved successfully
[SMART] Temperature: 35°C
[SMART] Wear Level: 12%
[SMART] Power On Hours: 1234
[SMART] Reallocated Sectors: 0
[INVENTORY] S.M.A.R.T. data retrieved via direct SCSI pass-through
```

### 4. Ellenőrizze a weboldalon:
- Nyissa meg: http://localhost:8080
- Menj a "New Test" tabra
- Válassza ki az USB SSD-t
- A hőmérséklet és wear level most már megjelenik!

## 🔧 Műszaki részletek:

### P/Invoke struktúrák:
```csharp
SCSI_PASS_THROUGH_DIRECT - SCSI parancsok küldésére
ATA_PASS_THROUGH_DIRECT - ATA parancsok küldésére
```

### IOCTL kódok:
```csharp
IOCTL_SCSI_PASS_THROUGH_DIRECT = 0x0004D014
IOCTL_ATA_PASS_THROUGH_DIRECT = 0x0004D02C
```

### SMART parancsok:
```
0xB0 - SMART parancs
0xD0 - SMART READ DATA
```

### CDB (Command Descriptor Block):
```
A1 10 00 00 00 01 00 00 00 00 B0 00
│  │  └─ Feature: 0xD0 (SMART READ DATA)
│  └─ Protocol: PIO Data-In
└─ ATA PASS THROUGH (12)
```

## ⚠️ Korlátozások:

### USB enclosure kompatibilitás:
✅ **Működik:**
- UASP-t támogató enclosure-ek
- SAT (SCSI-to-ATA Translation) támogató enclosure-ek
- Minőségi USB 3.x enclosure-ek (ORICO, Sabrent, Ugreen)

❌ **Nem működik:**
- Régi USB 2.0 enclosure-ek
- Néhány olcsó USB 3.0 enclosure
- Egyes JMicron chip-es enclosure-ek

### Admin jogok:
- Néhány USB enclosure admin jogokat igényel a S.M.A.R.T. adatok olvasásához
- Ha nem működik, próbálja meg adminisztrátorként futtatni a probe-ot

## 🔄 Hátralékos módszerek:

Ha a közvetlen S.M.A.R.T. olvasás nem működik, a probe automatikusan megpróbálja:

1. **Get-StorageReliabilityCounter** - PowerShell beépített parancs
2. **Get-PhysicalDisk** - Health status lekérdezése
3. **CIM lekérdezések** - Modellnév, sorozatszám, firmware

## 📝 Példa kimenet:

### Sikeres S.M.A.R.T. olvasás:
```
[INVENTORY] Processing disk #1: Samsung SSD 860 EVO
[INVENTORY] CIM data - Model: Samsung SSD 860 EVO, Serial: S3Z9NB0K123456, FW: RVT01B6Q
[INVENTORY] Attempting direct S.M.A.R.T. read via SCSI pass-through...
[SMART] Opening device: \\.\PhysicalDrive1
[SMART] Device opened successfully
[SMART] SMART data retrieved successfully
[SMART] Temperature: 35°C
[SMART] Wear Level: 12%
[SMART] Power On Hours: 1234
[SMART] Reallocated Sectors: 0
[INVENTORY] S.M.A.R.T. data retrieved via direct SCSI pass-through
[INVENTORY] Added drive: Samsung SSD 860 EVO | Bus: USB | Media: SSD | Letters: E
```

### Sikertelen S.M.A.R.T. olvasás (USB enclosure nem támogatja):
```
[INVENTORY] Processing disk #1: USB Disk
[INVENTORY] Attempting direct S.M.A.R.T. read via SCSI pass-through...
[SMART] Opening device: \\.\PhysicalDrive1
[SMART] DeviceIoControl failed (err=1)
[INVENTORY] Direct S.M.A.R.T. read failed: ...
[INVENTORY] USB device: S.M.A.R.T. data not accessible through USB enclosure
[INVENTORY] Added drive: USB Disk | Bus: USB | Media: Unknown | Letters: E
```

## 🎯 Előnyök:

✅ **Telepítés nélkül** - Nincs szükség smartmontools-ra vagy más szoftverre
✅ **Hordozható** - Csak a probe.ps1 fájl szükséges
✅ **Gyors** - Közvetlen API hívások, nincs overhead
✅ **Pontos** - Ugyanaz a módszer, mint a professzionális szoftverek
✅ **USB támogatás** - Működik USB-n keresztül is (ha az enclosure támogatja)

## 🔍 Hibaelhárítás:

### Ha nem működik:

1. **Ellenőrizze a probe konzolt:**
   - Látnia kell a `[SMART]` sorokat
   - Ha hibát lát, másolja be IDE

2. **Próbálja meg adminisztrátorként:**
   ```cmd
   # Jobb klikk a start-probe.bat-on
   # "Futtatás rendszergazdaként"
   ```

3. **Ellenőrizze az USB enclosure-t:**
   - Nézze meg, hogy támogatja-e az UASP-t vagy SAT-ot
   - Próbáljon meg másik USB portot
   - Próbáljon meg másik USB kábelt

4. **Közvetlen SATA/NVMe kapcsolat:**
   - Ha USB-n nem működik, próbálja meg közvetlenül
   - Csatlakoztassa az SSD-t az alaplapra

## 📚 Források:

- [SCSI Pass-Through Direct](https://docs.microsoft.com/en-us/windows/win32/api/winioctl/ni-winioctl-ioctl_scsi_pass_through_direct)
- [ATA Pass-Through Direct](https://docs.microsoft.com/en-us/windows/win32/api/winioctl/ni-winioctl-ioctl_ata_pass_through_direct)
- [S.M.A.R.T. Attributes](https://en.wikipedia.org/wiki/S.M.A.R.T.)
- [CrystalDiskInfo](https://crystalmark.info/en/software/crystaldiskinfo/)

## 🎉 Összefoglalás:

A probe most már **közvetlenül olvassa ki a S.M.A.R.T. adatokat** USB-n keresztül P/Invoke használatával, **telepítés nélkül**! Ez ugyanaz a módszer, amit a CrystalDiskInfo és más professzionális szoftverek használnak.

**További lépések:**
1. Indítsa újra a probe-ot
2. Csatlakoztassa az USB SSD-t
3. Ellenőrizze a probe konzolt és a weboldalt
4. Ha bármilyen problémája van, küldje el a probe konzol kimenetét
