# ios-galaxy

**iOS 16 (userland del iPhone 8) en un Samsung Galaxy J7 Neo (SM-J701M, Exynos 7870), preparado desde macOS.**

Este repo es una modificación de [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet), que porta el kernel XNU de Apple (xnu-8796, generación iOS 16) al Redmi Note 10 Pro y llega a la pantalla de inicio de iOS. Aquí el mismo kernel apunta al J7 Neo, y todos los pasos del host funcionan en macOS (Apple Silicon o Intel). Linux ya no es necesario.

> **Estado:** NO probado en el teléfono. El kernel compila en GitHub Actions y la CI revisa que solo use instrucciones ARMv8.0 (las que tiene el Cortex-A53; ver `NOTES.md`). El shim (el cargador que arranca S-BOOT) sí está probado en QEMU. Experimental: borra los datos de Android del teléfono.

## Qué cambia respecto al original

| Área | Redmi Note 10 Pro (original) | Galaxy J7 Neo (este repo) |
| --- | --- | --- |
| CPU | Cortex-A76/A55, ARMv8.2 | 8 x Cortex-A53, **ARMv8.0** (sin LSE, sin PAN). El kernel emula las instrucciones atómicas ARMv8.1 si iOS las usa |
| Páginas | 16 KB | **4 KB** (el A53 no tiene páginas de 16 KB) |
| Interrupciones | GICv3 | GIC-400 (GICv2) |
| Almacenamiento | UFS | eMMC (DW-MSHC), partición USERDATA (`rd=mmcroot0`) |
| Arranque | `fastboot boot` | S-BOOT de Samsung: imagen boot (v0 + dt.img) escrita en BOOT |
| RAM para iOS | 1,2-4 GB | 1 GB (el banco superior; el otro banco tiene el framebuffer en medio) |
| Pantalla | 1080x2400, iOS como iPhone X | 720x1280, iOS como **iPhone 8** (750x1334 escalado x0,96, pantalla completa) |
| Touch / botones | Goodix (GENI) / PMIC SPMI | Melfas MIP4 (I2C) / GPIO, botón Home real, touchkeys (Recientes = multitarea) |
| Batería | fija 100 % | medidor S2MU005 (lectura real, solo lectura) |
| USB | DWC3 Qualcomm | DWC3 Exynos + PHY + switch MUIC: red USB (CDC ECM) y log en vivo |

## App para Mac: iOS Galaxy

Todos los pasos de abajo también se hacen desde una app con un asistente de 10 pasos (`gui/`, SwiftUI, macOS 13 o más nuevo, Apple Silicon e Intel):

| Paso | Qué hace |
| --- | --- |
| 0 Herramientas | revisa adb, LLVM/lld, Python, lzfse, rsync 3, Heimdall… e instala lo que falta con Homebrew (sin `brew cleanup`); numpy va en un venv propio de la app (`~/Library/Application Support/iOS Galaxy/venv`); Heimdall se compila (`tools/heimdall-build.sh`) |
| 1 Repositorio | clona este repo en `~/ios-galaxy` o hace `git pull` |
| 2 TWRP | escribe una imagen de TWRP que eliges en RECOVERY con Heimdall (Download mode) |
| 3 Respaldo | `tools/j7-flash.sh backup` a `~/Documents/iOS Galaxy/backups/<fecha>` y copia BOOT.img a `dtb/stock-boot.img` |
| 4 Prueba del shim | imagen con ramdisk vacío, escribirla en BOOT, reiniciar |
| 5 Kernel | descarga el kernel de la release `latest` y revisa su SHA-256 |
| 6 iOS | lista de iOS 16 para iPhone10,4; descarga solo OS, SystemOS, AppOS y el DeviceTree (`tools/ipsw-fetch.py`); revisa el shared cache |
| 7 Imagen raíz | `tools/mkiosroot.sh` (contraseña de administrador) y escritura en USERDATA |
| 8 Arranque completo | `tools/j7-make-boot.sh` con cpus, payload en el kernel y boot-args; escritura en BOOT |
| 9 Logs | log del kernel desde TWRP, o en vivo por USB |

- Cada escritura en el teléfono pide escribir el nombre: `RECOVERY`, `BOOT` o `ERASE` (USERDATA).
- El estado del teléfono (TWRP/adb, Android, Download mode) se revisa cada 2 s; los botones que necesitan otro modo se desactivan y la app muestra las teclas.
- Puedes ir a cualquier paso; los hechos quedan marcados.

**Descargar:** `iOS-Galaxy.app.zip` de la [release `latest`](https://github.com/my-company-my/ios-galaxy/releases/tag/latest) (la CI la reemplaza en cada ejecución que pasa, junto con el kernel). La app está firmada ad hoc, no por un desarrollador de Apple: la primera vez macOS la bloquea. Ábrela una vez, luego **Ajustes del Sistema › Privacidad y seguridad › Abrir de todos modos**. O en Terminal: `xattr -dr com.apple.quarantine "/Applications/iOS Galaxy.app"`.

**Compilarla en tu Mac** (Xcode o Command Line Tools): `gui/build-app.sh` → `gui/out/iOS Galaxy.app`.

## Qué necesitas

- Galaxy J7 Neo **SM-J701M** con **OEM unlock** activado (Opciones de desarrollador) y "OEM LOCK: OFF" en Download mode.
- TWRP para j7velte (Exynos 7870) en la partición RECOVERY.
- Un Mac con [Homebrew](https://brew.sh):
  ```sh
  brew install llvm lld python android-platform-tools lzfse qemu
  brew install blacktop/tap/ipsw          # extraer archivos del IPSW
  pip3 install numpy pillow
  ```
- Para instalar TWRP la primera vez: Odin (Windows) o [Heimdall](https://git.sr.ht/~grimler/Heimdall) compilado en el Mac.
- El kernel: GitHub Actions de este repo (runner macOS) o tu Mac con **Xcode 15.x o 16.x** (`tools/build-xnu-mac.sh`).

## Pasos

### 0. TWRP y respaldo

No hay TWRP oficial para el J7 Neo (j7velte). Uno no oficial que sirve: `TWRP-3.7.1-j7velte-@Batuhantrkgl.img` de la release [TWRP-3.7.1-Exynos7870-Stable](https://github.com/batuhantrkgl/releases/releases/tag/TWRP-3.7.1-Exynos7870-Stable) (también en [SourceForge](https://sourceforge.net/projects/batuhan-s-builds/files/TWRP-3.7.1-Exynos7870-Stable/)). SHA-256 del archivo revisado: `696cc964d70c6fdb86952b477f9afd5a2adefa3e259eea32c5df31db8f52b69f` (30 072 832 bytes). Lo que se revisó en ese archivo: `ro.product.device=j7velte`; device trees "J7VE LTE" para el chip 7870 (0x1ebe) con hw_rev 0-255; particiones en `13540000.dwmmc0/by-name` (BOOT, RECOVERY, USERDATA…); adb activado con shell root y `blockdev`/`dd`/`readlink` (lo que usa `tools/j7-flash.sh`). Sus device trees son de la variante SEA (SM-J701F); S-BOOT elige el device tree por chip y hw_rev (el port de postmarketOS probado en el SM-J701M solo da esos), así que debería arrancar en el J701M, pero eso no está probado.

```sh
heimdall flash --RECOVERY twrp-j7velte.img --no-reboot   # desde Download mode (Vol- + Home + Power)
# arrancar TWRP: Vol+ + Home + Power
tools/j7-flash.sh backup backup/                         # BOOT, RECOVERY, EFS, PARAM, RADIO...
cp backup/BOOT.img dtb/stock-boot.img                     # el shim usa su cabecera y su dt.img
```

`backup/` y `dtb/` no entran a git (EFS tiene el IMEI). Guárdalos aparte.

### 1. Kernel

Con GitHub Actions: cada push a `xnu/patches/` corre `.github/workflows/xnu.yml`; descarga el artifact `xnu-kernel` a `xnu/out/`. En tu Mac:

```sh
tools/build-xnu-mac.sh          # -> xnu/out/kernel.development.sweet
```

### 2. IPSW del iPhone 8 y revisión de instrucciones

Descarga el IPSW de iOS 16.7.x para iPhone 8 (iPhone10,4; el mismo archivo sirve para iPhone10,1) desde Apple ([ipsw.me](https://ipsw.me/iPhone10,4)). En `BuildManifest.plist` busca los nombres de las imágenes `OS`, `Cryptex1,SystemOS` y `Cryptex1,AppOS`.

Antes de flashear, revisa si el userland usa instrucciones que el A53 no tiene:

```sh
hdiutil attach -readonly -nobrowse SystemOS.dmg -mountpoint /tmp/sysos
python3 tools/check-armv80.py /tmp/sysos/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64*
```

`lse` y `ldapr` los emula el kernel. Si aparecen `fp16`, `dotprod`, `rdm`, `fjcvtzs` o `ldapur` en código que corre sin revisar la CPU, iOS fallará ahí.

### 3. Device tree del iPhone 8

```sh
python3 tools/remotezip.py IPSW_URL Firmware/all_flash/DeviceTree.d201ap.im4p research/ipsw-8
python3 tools/adt.py unwrap research/ipsw-8/Firmware/all_flash/DeviceTree.d201ap.im4p research/ipsw-8/d201ap.adt
```

`tools/mkadt.py` copia `/product` y `/buttons` de ese árbol (MobileGestalt los necesita).

### 4. Imagen raíz de iOS

```sh
tools/mkiosroot.sh OS.dmg SystemOS.dmg AppOS.dmg ios16-root.img 3g   # 3g = espacio libre extra
```

Monta el IPSW con `hdiutil`, copia todo a un HFS+ sensible a mayúsculas, aplica `tools/sweet-root-tweaks.py` y revisa el volumen con `fsck_hfs`. Pide la contraseña de `sudo`.

### 5. Imagen boot

```sh
tools/j7-make-boot.sh xnu/out/kernel.development.sweet            # cpus=1 para la primera prueba
tools/j7-make-boot.sh xnu/out/kernel.development.sweet --cpus 8   # después, los 8 núcleos
```

Prueba primero solo el shim, sin kernel: `shim/build.sh` (ramdisk vacío). Muestra la CPU, el nivel de excepción y si encuentra el ramdisk. Si dice `INITRD none in /chosen`, usa `--payload-in-kernel`.

### 6. Flashear y arrancar (en TWRP)

```sh
tools/j7-flash.sh root ios16-root.img     # borra USERDATA; pide escribir ERASE
tools/j7-flash.sh boot shim/out/shim-boot.img
adb reboot
```

### 7. Leer el log

El kernel guarda la consola en los últimos 4 MiB de USERDATA. Arranca TWRP (mantén Power + Vol- para reiniciar, luego Vol+ + Home + Power) y:

```sh
tools/sweet-log-pull.sh logs/boot.txt
```

Con USB conectado y el kernel corriendo: `tools/sweet-usbnet.sh` muestra el log en vivo (red 192.168.7.x).

### Volver a Android

Flashea el firmware oficial de Samsung con Odin, o `tools/j7-flash.sh boot backup/BOOT.img` y formatea Data en TWRP.

## Boot-args

| Boot-arg | Efecto |
| --- | --- |
| `rd=mmcroot0 mmcrw=1 rootrw=1` | raíz en USERDATA, escribible |
| `mmcroot=NOMBRE` | otra partición GPT (por defecto USERDATA) |
| `cpus=N` | núcleos a iniciar (1-8) |
| `sweetfb_noconsole=1` / `sweetfb_hz=20` | quita el texto del kernel de la GUI / frecuencia de copia a la pantalla |
| `sweetfb_native=1` | presenta 720x1280 a iOS en lugar del tamaño del iPhone 8 |
| `sweettouch=0`, `sweettouchpoll=1` | sin touch / leer el touch sin mirar su línea de interrupción |
| `sweetkeys=0`, `sweettouchkeys=0` | sin botones / sin touchkeys |
| `sweetbattery=0` | batería fija 100 % |
| `sweetusb=0`, `sweetusblog=0` | sin USB / sin log en vivo |
| `sweetlog=0`, `mmclogsecs=N` | sin log persistente / cada cuántos segundos se escribe |

## Pruebas sin teléfono

```sh
SHIM_IMAGE_ONLY=1 shim/build.sh
python3 tools/qemu-j7.py --boot-mpidr 0x102 --el2   # shim -> kernel de prueba en QEMU
python3 tools/test/lse_test.py                      # emulación de atómicos ARMv8.1
python3 tools/validate-repo.py
```

## Estructura

| Ruta | Qué es |
| --- | --- |
| `shim/` | cargador bare-metal (C + asm) que S-BOOT arranca como kernel |
| `xnu/patches/0001-0081` | port original (Redmi), genérico de iOS en su mayoría |
| `xnu/patches/0082-0088` | J7 Neo: CPU/GIC/páginas 4K, emulación LSE, eMMC, GPIO/I2C/touch/botones/batería, pantalla iPhone 8, USB; compatibilidad con el iig de Xcode 16 |
| `tools/` | ADT, payload, boot.img, imagen raíz, flasheo, logs, pruebas |
| `docs/` | notas y README del port original al Redmi |
