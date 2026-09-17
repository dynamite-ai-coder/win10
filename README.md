# render-ssh-service

Szablon usługi web na [Render](https://render.com) (Docker) z natywnym dostępem SSH do instancji.

## Zawartość

| Plik | Opis |
| --- | --- |
| `Dockerfile` | Obraz z nieuprzywilejowanym użytkownikiem `app` i katalogiem `~/.ssh` (0700) — zgodny z wymaganiami SSH Render |
| `app.py` | Serwer HTTP (tylko stdlib): `GET /` — info o instancji, `GET /health` — healthcheck |
| `render.yaml` | Blueprint Render: web service + healthcheck + płatny plan |
| `scripts/connect.sh` | Pomocnik do łączenia się przez SSH |

## Wymagania

- konto Render,
- **płatny plan instancji** — Free nie obsługuje SSH ani Shell,
- publiczny klucz SSH dodany do konta Render.

## Deploy

1. Repozytorium na GitHubie:

   ```bash
   git init
   git add .
   git commit -m "render ssh service"
   git remote add origin git@github.com:UZYTKOWNIK/render-ssh-service.git
   git push -u origin main
   ```

2. Render Dashboard → **New → Blueprint** → wybierz repo (Render wykryje `render.yaml`).

   lub przez CLI:

   ```bash
   render blueprint launch
   ```

3. Ręcznie (alternatywa): **New → Web Service → Docker**, healthcheck `/health`.

## Klucz SSH

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
```

Render Dashboard → **Account Settings → SSH Public Keys** → wklej zawartość `~/.ssh/id_ed25519.pub`.

## Połączenie z usługą

```bash
# bezpośrednio
ssh srv-XXXXXXXX@ssh.frankfurt.render.com

# Render CLI
render ssh srv-XXXXXXXX

# skrypt z repo
./scripts/connect.sh srv-XXXXXXXX frankfurt

# konkretna instancja (5-znakowy slug widoczny w logach)
ssh srv-XXXXXXXX-d4e5f@ssh.frankfurt.render.com
```

Adresy SSH: `ssh.<region>.render.com` dla regionów `oregon`, `ohio`, `virginia`, `frankfurt`, `singapore`.

## Endpointy

- `GET /` — hostname, użytkownik, uptime, platforma
- `GET /health` — `{"status": "ok"}`

## Ograniczenia

- System plików jest efemeryczny — zmiany z sesji SSH znikają po redeployu/restarcie.
- Render zamyka aktywne sesje SSH przy każdym redeployu lub restarcie usługi.
- Obraz **nie może** uruchamiać własnego `sshd` ani niczego na porcie 22 — SSH obsługuje Render.
- Obrazy minimalne (distroless) nie wspierają SSH ani shella.
- Sesja SSH zużywa pamięć z puli instancji (~2 MB + ~3 MB na sesję).

## Bezpieczeństwo

- Nie commituj kluczy prywatnych ani tokenów API — `.gitignore` to uwzględnia.
- Token API lub klucz wklejony publicznie uznaj za spalony i natychmiast go zrotuj.
