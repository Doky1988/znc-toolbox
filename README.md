# ZNC Toolbox

**Telepítő, Frissítő és Eltávolító eszköz ZNC IRC Bouncerhez — Debian / Ubuntu rendszerekre.**

Fordítja a ZNC-t forráskódból a legfrissebb stabil verzióra, systemd szolgáltatásként telepíti, kezeli a frissítéseket a konfiguráció megtartásával, és igény esetén teljesen eltávolítja.

---

## Funkciók

- **Telepítés** — legfrissebb stabil ZNC letöltése, fordítása, telepítése `/home/znc/znc` alá
- **Frissítés** — új verzióra frissítés a meglévő konfiguráció megtartásával és biztonsági mentéssel
- **Eltávolítás** — ZNC, konfiguráció, systemd szolgáltatás, felhasználó és home könyvtár teljes törlése
- **Állapot** — telepített verzió, elérhető frissítés, szolgáltatás állapotának ellenőrzése
- **Interaktív menü** — könnyen áttekinthető dobozos felület
- **IPv6 támogatás** — telepítéskor választható, frissítéskor automatikusan megtartva
- **Port ellenőrzés** — telepítés után jelzi, hogy a port nyitva van-e
- **Webadmin URL** — külső IP címmel együtt kiírva
- **Naplózás** — minden művelet a `/var/log/znc-toolbox.log` fájlba kerül

---

## Rendszerkövetelmények

- Debian vagy Ubuntu (bármely támogatott verzió)
- Root jogosultság (`sudo`)
- Internetkapcsolat (letöltéshez és külső IP lekéréséhez)

---

## Telepítés és használat

### Letöltés

```bash
wget https://raw.githubusercontent.com/<user>/<repo>/main/znc-toolbox.sh](https://raw.githubusercontent.com/Doky1988/znctoolbox/refs/heads/main/znc-toolbox.sh
chmod +x znc-toolbox.sh
```

### Interaktív menü

```bash
sudo ./znc-toolbox.sh
```

```
  ┌────────────────────────────────────────────┐
  │          ZNC Toolbox - By Doky             │
  ├────────────────────────────────────────────┤
  │            ZNC nincs telepítve             │
  ├────────────────────────────────────────────┤
  │  1) Telepítés                              │
  │  2) Frissítés                              │
  │  3) Eltávolítás                            │
  │  4) Állapot                                │
  │  0) Kilépés                                │
  └────────────────────────────────────────────┘
```

### Parancssori mód

```bash
sudo ./znc-toolbox.sh install      # ZNC telepítése
sudo ./znc-toolbox.sh update       # ZNC frissítése
sudo ./znc-toolbox.sh uninstall    # ZNC eltávolítása
sudo ./znc-toolbox.sh status       # Állapot lekérése
sudo ./znc-toolbox.sh help         # Súgó
```

---

## Telepítés menete

1. **OS és root ellenőrzés**
2. **IPv6 választás** — engedélyezed az IPv6 támogatást?
3. **Verzió választás** — alapértelmezett a legfrissebb, de megadhatsz egyedit is (pl. `1.9.1`)
4. **Függőségek telepítése** — `build-essential`, `cmake`, `libssl-dev`, stb.
5. **ZNC letöltése és fordítása** — pont-animációval, a build kimenet naplózva
6. **`znc` rendszerfelhasználó létrehozása** — `/home/znc` home könyvtárral
7. **`--makeconf` varázsló** — interaktív konfiguráció (port, admin jelszó, IRC hálózatok)
8. **Systemd szolgáltatás** — automatikus indítás rendszerindításkor
9. **Port ellenőrzés** — a beállított port figyelésének ellenőrzése

### Telepítési összegző

```
  ═══ ZNC telepítve ═══

  Bináris    /home/znc/znc/bin/znc
  Konfig     /home/znc/.znc/configs/znc.conf
  Szolg.     znc.service (fut)
  Verzió     ZNC 1.10.2 - https://znc.in
  Port       11337 (nyitva)
  Webadmin   http://123.45.67.89:11337/

  Parancsok:
  systemctl start znc       ▸ indítás
  systemctl stop znc        ▸ leállítás
  systemctl restart znc     ▸ újraindítás
  systemctl status znc      ▸ állapot lekérése
  journalctl -u znc -f      ▸ napló követése
  sudo -u znc ... --makeconf▸ újrakonfigurálás
```

---

## Frissítés menete

1. Meglévő konfiguráció biztonsági mentése (`znc.conf.bak-<időbélyeg>`)
2. ZNC szolgáltatás leállítása
3. Régi bináris törlése
4. Új verzió letöltése és fordítása
5. Szolgáltatás újraindítása — a konfiguráció változatlan marad

### Frissítési összegző

```
  ═══ ZNC frissítve ═══

  Bináris    /home/znc/znc/bin/znc
  Konfig     /home/znc/.znc/configs/znc.conf
  Szolg.     znc.service (fut)
  Verzió     1.9.1 ▸ 1.10.2
  Port       11337 (nyitva)
  Webadmin   http://123.45.67.89:11337/

  Parancsok:
  systemctl restart znc     ▸ újraindítás
  systemctl status znc      ▸ állapot lekérése
  journalctl -u znc -f      ▸ napló követése
```

---

## Konfigurációs fájlok

| Fájl | Leírás |
|---|---|
| `/home/znc/.znc/configs/znc.conf` | ZNC konfiguráció |
| `/home/znc/.znc/toolbox-flags` | IPv6 beállítás (frissítéshez) |
| `/etc/systemd/system/znc.service` | Systemd szolgáltatás |
| `/var/log/znc-toolbox.log` | Toolbox napló |

---

## Megjegyzések

- A függőségek (`build-essential`, `cmake`, stb.) az eltávolítás után is a rendszeren maradnak, mivel más programok is használhatják
- A `--makeconf` varázsló végén válaszd a **No**-t, hogy a ZNC ne induljon el a konfigurálás után — a script a systemd szolgáltatáson keresztül indítja el
- Frissítéskor a régi IPv6 beállítás automatikusan megmarad
- A külső IP cím az `ipinfo.io` szolgáltatáson keresztül kerül lekérésre

---

## Licensz

[MIT](LICENSE)
