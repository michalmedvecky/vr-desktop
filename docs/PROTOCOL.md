# Protokol Mac ↔ Quest

Verze 1. Vše běží v lokální síti, bez autentizace.

## 1. Signalizace (HTTPS, port 8443)

| Požadavek | Popis |
| --- | --- |
| `GET /` | webový klient (`index.html`, `app.js`, `three.module.min.js`) |
| `POST /offer` | tělo `{"sdp": "<offer>"}`, odpověď `{"sdp": "<answer>"}` |

Port 8080 (HTTP) jen přesměruje na HTTPS.

Klient je **offerer** a ICE je **non-trickle**: klient počká na dokončení sběru kandidátů, pošle
offer, Mac odpoví answerem, který už obsahuje všechny své kandidáty. Každý nový `POST /offer`
nahradí předchozí spojení.

Offer obsahuje:

* 4 video transceivery `recvonly` (sloty 0–3, v tomto pořadí),
* data channel `ctl` (ordered).

Mac na každý slot připojí stálou video stopu. Výběr jiných oken jen přepne, které okno do slotu
teče, takže se nikdy znovu nevyjednává. Preferovaný kodek je H.264.

### Varianta: přes relay server (`server/`)

Když stránku servíruje veřejný relay (Kubernetes), adresa nese párovací kód:
`https://<server>/#<room>` (`room` = 16–128 znaků `[A-Za-z0-9_-]`).

* Mac: `wss://<server>/ws?role=host&room=<room>` (trvalé spojení, server ho pinguje každých 25 s)
* Quest: `wss://<server>/ws?role=client&room=<room>` (jen na dobu výměny offer/answer)

```json
Quest → server:  {"type":"offer","sdp":"…"}
server → Mac:    {"type":"offer","sdp":"…","from":"<client-id>"}
Mac → server:    {"type":"answer","sdp":"…","to":"<client-id>"}   nebo {"type":"error","message":"…","to":"…"}
server → Quest:  {"type":"answer","sdp":"…"}
server → Quest:  {"type":"error","message":"Mac není připojený k serveru"}
```

Offer i answer jsou stejné jako u `POST /offer` (non-trickle). Média jdou přímo Mac ↔ Quest.

## 2. Data channel `ctl`

JSON zprávy. Řídicí zprávy mají pole `type`, vstupní pole `t`.

### Mac → Quest

```json
{"type":"hello","name":"Mac Pro","version":1,"maxWindows":4}
{"type":"windows","windows":[{"id":1234,"title":"README.md","app":"Xcode","width":1440,"height":900}]}
{"type":"slots","slots":[1234,0,5678,0]}
{"type":"error","message":"…"}
```

* `windows`: všechna okna, která jde streamovat. `width`/`height` v bodech (points).
* `slots[i]`: ID okna, které právě teče ve video slotu `i` (0 = prázdný). Je to zároveň aktuální
  výběr oken.

### Quest → Mac

```json
{"type":"listWindows"}
{"type":"select","windowIds":[1234,5678]}
```

`select` nastaví úplný výběr (max `maxWindows`). Mac odpoví `slots`.

### Vstup (Quest → Mac)

Souřadnice `x`, `y` jsou normalizované vůči oknu: (0,0) vlevo nahoře, (1,1) vpravo dole.

```json
{"t":"mouse","w":1234,"x":0.42,"y":0.17,"a":"move|down|up","b":0}
{"t":"scroll","w":1234,"x":0.42,"y":0.17,"dx":0,"dy":-120}
{"t":"key","key":"c","down":true,"mods":["cmd","shift","alt"]}
{"t":"text","s":"Ahoj"}
```

* `b`: 0 = levé, 1 = pravé, 2 = prostřední tlačítko. Při `down` Mac okno aktivuje a přenese
  do popředí. Dvojklik Mac pozná sám podle času a vzdálenosti kliků.
* `scroll`: pixely, kladné `dy` = posun nahoru.
* `key`: pojmenované klávesy (`return`, `tab`, `escape`, `backspace`, `delete`, `left`, `right`,
  `up`, `down`, `home`, `end`, `pageup`, `pagedown`, `space`, `f1`–`f12`) nebo písmena/číslice
  (pro zkratky jako Cmd+C).
* `text`: libovolný Unicode text, napíše se nezávisle na rozložení klávesnice.
