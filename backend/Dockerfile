FROM python:3.12-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
# --only-binary :all: evita ejecutar scripts de instalacion (setup.py) de
# dependencias. Se verifico que todas tienen wheel para linux/amd64 + py3.12.
# NOSONAR (docker:S8544): las versiones ya estan fijadas de forma exacta (==)
# en requirements.txt; el pin por hash obligaria a regenerar un lock completo en
# cada cambio de dependencia y se descarta a proposito.
RUN pip install --no-cache-dir --only-binary :all: -r requirements.txt  # NOSONAR

COPY app ./app

RUN mkdir -p downloads temp

EXPOSE 10000

# --proxy-headers + --forwarded-allow-ips=*: trust the platform proxy so the
# real client IP reaches the app (used for logging and rate limiting).
# Se ejecuta como root a proposito: en Render el disco persistente (descargas)
# se monta propiedad de root, y un usuario sin privilegios no podria escribir en
# el. Riesgo aceptado y documentado (docker:S6471). Si algun dia el disco deja
# de ser necesario, mover a un usuario sin privilegios es seguro.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-10000} --proxy-headers --forwarded-allow-ips=*"]
