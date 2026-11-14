# VR Desktop

Vybraná okna z Macu jako samostatné panely ve virtuálním prostoru Meta Quest. Panely jde
rozmístit kamkoli, zvětšovat, zmenšovat a ovládat (myš, scroll, klávesnice jdou zpět do Macu).

## Jak to funguje

```
Mac (VRDesktop.app, menu bar)                          Quest (prohlížeč, WebXR)
┌──────────────────────────────┐   HTTPS :8443         ┌───────────────────────────┐
│ ScreenCaptureKit (po oknech) │ ──────────────────▶   │ stránka + three.js        │
│ WebRTC, H.264 (VideoToolbox) │   WebRTC video        │ 1 video = 1 panel v 3D    │
│ CGEvent / Accessibility      │ ◀──────────────────   │ ovladače, BT klávesnice   │
└──────────────────────────────┘   data channel "ctl"  └───────────────────────────┘
```

* **Mac**: aplikace v liště (`mac/`, Swift). Zachytává zvolená okna (max 4), kóduje je hardwarově
  do H.264 a posílá přes WebRTC. Vstup z Questu přehrává do správného okna (CGEvent).
* **Quest**: webový klient (`mac/Web/`), který Mac sám servíruje přes HTTPS. Nic se neinstaluje
  do brýlí. Protokol je popsaný v [docs/PROTOCOL.md](docs/PROTOCOL.md).
* Bez autentizace, jen pro lokální síť (prototyp). Spojení je šifrované (HTTPS + DTLS ve WebRTC),
  certifikát je ale self-signed.

## Spuštění (prototyp)

### 1. Mac

1. Stáhni `VRDesktop.zip` z [Releases → prototype](../../releases/tag/prototype) a rozbal ho.
2. Přesuň `VRDesktop.app` do složky Aplikace.
3. Aplikace není podepsaná Apple certifikátem, takže ji macOS napoprvé zablokuje. V Terminálu spusť:
   ```
   xattr -dr com.apple.quarantine /Applications/VRDesktop.app
   ```
   (nebo: dvojklik → Systémové nastavení → Soukromí a zabezpečení → „Přesto otevřít“).
4. Spusť ji. V liště nahoře se objeví ikona dvou obdélníků.
5. macOS se zeptá na oprávnění. Povol:
   * **Nahrávání obrazovky a systémového zvuku** (Soukromí a zabezpečení). Po povolení aplikaci
     ukonči a spusť znovu.
   * **Zpřístupnění** (Accessibility), aby šlo okna ovládat z Questu.
   * **Lokální síť**, pokud se zeptá.
6. Klikni na ikonu v liště: uvidíš adresu typu `https://192.168.1.23:8443` a seznam oken.
   Okna můžeš zaškrtnout tady, nebo později přímo v brýlích.

### 2. Quest

1. Quest musí být ve stejné Wi-Fi jako Mac.
2. Otevři **Prohlížeč** a zadej adresu z menu (včetně `https://` a `:8443`).
3. Prohlížeč varuje před certifikátem (je self-signed): **Rozšířené → Pokračovat na … (nebezpečné)**.
   Adresu si ulož do záložek.
4. Klikni na **Vstoupit do VR**.

### Ovládání ve VR

| Akce | Ovládání |
| --- | --- |
| Klik, tažení | spoušť (ukazovák) |
| Pravé tlačítko | A / X |
| Scroll | páčka, když míříš na okno |
| Přesun okna | grip (prostředníček) na okně, nebo spoušť na liště okna |
| Zvětšit / zmenšit oběma rukama | chyť okno jednou rukou (spoušť nebo grip), pak stiskni spoušť nebo grip druhou rukou (stačí mířit vedle okna) a roztáhni / stáhni ruce. Okraj okna zezelená. |
| Blíž / dál | při držení gripu páčka nahoru / dolů |
| Větší / menší | při držení gripu páčka doprava / doleva |
| Seznam oken (výběr) | B / Y |
| Zavřít panel | × na liště okna (okno na Macu zůstane) |
| Psaní | Bluetooth klávesnice spárovaná s Questem. Ctrl i Cmd fungují jako Cmd. |

Rozmístění panelů si prohlížeč pamatuje (podle aplikace a názvu okna).

Obsah oken vykresluje přímo kompozitor Questu (WebXR media layers), takže text je ostrý
a nebliká. V seznamu oken (B/Y) je vidět verze klienta a „vrstvy: ano/ne“. Kdyby okna byla
černá, přidej do adresy `?nolayers` (např. `https://…:8443/?nolayers`) a pošli mi, co vidíš.

### Přes vlastní server (stálá adresa, platný certifikát)

Webového klienta a signalizaci můžeš provozovat na vlastním Kubernetes clusteru s veřejnou IP
a certifikátem Let's Encrypt. Quest pak otevírá `https://vr.example.com/#<kód>` bez varování
o certifikátu. Video jde dál přímo z Macu do Questu v lokální síti. Návod: [k8s/README.md](k8s/README.md).

### Bez brýlí

Stejnou adresu jde otevřít i v Chrome na počítači: panely se zobrazí ve 3D a ovládají se myší.
Hodí se na rychlou kontrolu, že streamování funguje.

## Řešení problémů

* **Panel je šedý/černý**: zkontroluj oprávnění Nahrávání obrazovky a aplikaci restartuj.
* **Kliky nic nedělají**: chybí oprávnění Zpřístupnění. Po povolení aplikaci restartuj.
  Pozor: klik z Questu opravdu pohne kurzorem na Macu.
* **Quest se nepřipojí**: Mac a Quest musí být ve stejné síti a firewall na Macu musí povolit
  příchozí spojení pro VR Desktop. Zkus adresu otevřít z jiného počítače.
* **Text je rozmazaný**: přibliž panel (grip + páčka nahoru). Quest 2 má omezené rozlišení.
  Menší okna na Macu = ostřejší text.

## Vývoj

* Mac aplikace: `cd mac && swift run` (Xcode: `open mac/Package.swift`). Sestavení `.app`:
  `mac/scripts/build-app.sh`. GitHub Actions ji sestaví na každý push a vydá jako pre-release
  `prototype`.
* Webový klient bez Macu: `pip install aiortc aiohttp && python tools/fake_mac.py`, pak
  `https://localhost:8443`. Simuluje Mac s testovacími okny a vypisuje přijatý vstup.
* Relay server: `cd server && npm ci && npm test`, lokálně `npm start` (port 8080). Simulovaný Mac
  přes relay: `python tools/fake_mac.py --relay http://localhost:8080 <kód>`, pak
  `http://localhost:8080/#<kód>`.

## Další kroky

* Nativní klient v Unity (OpenXR) pro lepší výkon a ostřejší text (compositor layers).
* Párování a autentizace (TLS s ověřením, případně SSH tunel).
* Zakřivené panely, passthrough, zvuk, ovládání rukama.
