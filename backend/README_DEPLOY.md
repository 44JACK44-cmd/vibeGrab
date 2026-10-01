# Despliegue del backend VibeGrab (gratis)

El backend (FastAPI + yt-dlp) es parte del producto. Publícalo una vez y la app
funciona desde cualquier lugar apuntando a esa URL. Verificado en 2026:
**Render** es la opción gratis más simple (sin tarjeta).

## Opción recomendada: Render (gratis, sin tarjeta)

1. **Sube el proyecto a GitHub** (ya lo haces): incluye la carpeta `backend/`
   con `Dockerfile`, `requirements.txt` y `app/`.

2. **Crea el servicio en Render**
   - Entra a https://dashboard.render.com → **New +** → **Web Service**
   - Conecta tu repositorio de GitHub.
   - Configura:
     - **Name**: `vibegrab-api`
     - **Runtime**: `Docker`
     - **Root Directory**: `backend` ← importante (el Dockerfile está ahí)
     - **Instance Type**: **Free**
   - **Create Web Service** → espera el build (~3-5 min).

3. **Tu URL queda en**: `https://vibegrab-api.onrender.com`
   - Verifica: `https://vibegrab-api.onrender.com/api/health` → `{"status":"ok"}`

4. **Mantén el servicio despierto (gratis)** — el plan Free se duerme a los
   15 min sin peticiones:
   - Cuenta gratis en https://uptimerobot.com → **Add New Monitor** → tipo
     **HTTP(s)** → URL: `https://vibegrab-api.onrender.com/api/health` →
     intervalo **5 minutos** → crear.
   - Así nunca duerme (750 h/mes gratis alcanzan para estar siempre activo).

5. **Pon la URL en la app**
   - VibeGrab → **Ajustes → URL del backend** →
     `https://vibegrab-api.onrender.com` (sin `/api`).

Notas de Render Free:
- RAM 512 MB — suficiente para yt-dlp (usa una instancia, no concurrentes).
- Si ves lentitud la primera vez (~40 s), es el arranque en frío: UptimeRobot
  lo evita.
- El límite es 750 h/mes por servicio; un ping cada 5 min lo mantiene dentro.

## Opción alternativa: Oracle Cloud Always Free (tarjeta sin cargo)

Si quieres always-on con más potencia (2 OCPU ARM + 12 GB gratis para siempre):

1. https://www.oracle.com/cloud/free/ → crea cuenta (pide tarjeta de
   identificación, **no cobra**).
2. Crea una VM **Ampere A1** (Always Free) con Ubuntu.
3. Instala Docker (`curl -fsSL https://get.docker.com | sh`).
4. Sube `backend/` (scp o desde GitHub) y:
   ```bash
   docker build -t vibegrab .
   docker run -d --name vibegrab -p 8000:8000 vibegrab
   ```
5. Abre el puerto 8000 en la lista de seguridad (Ingress rules) y pon
   `http://IP_PUBLICA:8000` en la app.

## Verificación final

```bash
curl https://TU_URL/api/health
curl -X POST https://TU_URL/api/analyze -H "Content-Type: application/json" \
     -d '{"url":"https://www.tiktok.com/@usuario/video/123"}'
```

## Notas importantes

- **YouTube funciona 100% en el celular** (no usa backend).
- **TikTok/Instagram/etc. usan el backend**: yt-dlp resuelve los retos
  anti-bot y la descarga pasa por `/api/fetch` (los CDN bloquean peticiones
  sin cookies de sesión — comprobado en pruebas).
- Si TikTok falla en el servidor: `pip install -U --pre "yt-dlp[default]"` y
  redeploy (Render: redeploy automático con cada push a GitHub).
- **No uses Hugging Face Spaces para esto**: desde 2026 los Docker Spaces
  requieren plan PRO de pago.
