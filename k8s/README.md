# Nasazení serverové části do Kubernetes

Server (`server/`) dělá dvě věci:

1. **Servíruje webového klienta pro Quest** přes HTTPS s certifikátem Let's Encrypt. Odpadá
   varování o self-signed certifikátu a adresa je stálá (záložka v prohlížeči Questu).
2. **Signalizační relay**: Mac aplikace se k serveru připojí odchozím WebSocketem, Quest přes
   něj pošle WebRTC offer a dostane odpověď. Server neukládá nic na disk a nevidí obraz.

**Video jde dál přímo z Macu do Questu** (WebRTC), server jím neprochází. Mac a Quest proto
musí být ve stejné síti. Pro použití přes internet by bylo potřeba přidat TURN server.

```
Quest ──HTTPS/WSS──▶ vr.example.com (K8s) ◀──WSS── Mac
  ▲                                                   │
  └──────────── WebRTC video přímo v LAN ─────────────┘
```

## Předpoklady

* ingress controller (manifest počítá s `ingress-nginx`; pro Traefik změň `ingressClassName`
  a anotace nginx klidně smaž)
* cert-manager s `ClusterIssuer` pro Let's Encrypt (v manifestu `letsencrypt-prod`)
* DNS záznam domény (např. `vr.example.com`) na veřejnou IP clusteru

## Nasazení

1. V `k8s/kustomization.yaml` přepiš `vr.example.com` na svou doménu (obě místa). Případně uprav
   název `ClusterIssuer` a `ingressClassName` v `k8s/ingress.yaml`.
2. Nasaď:
   ```
   kubectl apply -k k8s/
   kubectl -n vr-desktop get pods,ingress,certificate
   ```
3. Ověř: `https://vr.example.com/healthz` vrací `ok` a `https://vr.example.com/` ukáže stránku
   VR Desktop s platným certifikátem.

Image `ghcr.io/michalmedvecky/vr-desktop-server` staví GitHub Actions (`server-image.yml`) pro
amd64 i arm64 při každé změně serveru nebo webového klienta. Tagy: `latest` a SHA commitu. Pro
stabilní nasazení nastav v `kustomization.yaml` místo `latest` konkrétní SHA.

Pokud by image na GHCR nebyl veřejný: GitHub → tvůj profil → Packages → `vr-desktop-server` →
Package settings → Change visibility → Public.

Server drží místnosti v paměti, proto běží **přesně 1 replika** (Mac i Quest se musí potkat
na stejném podu). Restart podu nevadí: Mac se sám znovu připojí.

## Připojení Macu

1. V aplikaci VR Desktop (ikona v liště) rozbal **Přes server (Kubernetes)**.
2. Zadej `https://vr.example.com` a klikni **Uložit**. Stav se změní na „připojeno“.
3. Zobrazí se odkaz `https://vr.example.com/#<kód>`. Ten otevři v prohlížeči Questu a ulož
   do záložek.

## Bezpečnost

Nasazený server je veřejný, takže přístup chrání **tajný párovací kód** v odkazu (192 bitů
náhody, generuje ho Mac). Kdo zná odkaz, vidí sdílená okna a může je ovládat. Kód je za `#`,
takže ho prohlížeč neposílá na server v URL a neobjeví se v logu ingressu. Při úniku klikni na
**Nový kód**: staré odkazy přestanou fungovat.

Šifrování: HTTPS/WSS na serveru (Let's Encrypt), video a vstup šifruje WebRTC (DTLS-SRTP)
end-to-end mezi Macem a Questem.
