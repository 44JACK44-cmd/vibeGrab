"""Crea/actualiza secretos de GitHub Actions via API con cifrado sealed box.

Los valores se cifran con la clave publica del repositorio (libsodium sealed
box), exactamente igual que cuando se pegan en la web de GitHub, de modo que
nunca viajan en claro. Pensado para automatizar la firma APK sin depender de
un portatil.

Uso (Python 3.9+, requiere `pynacl`):

    GITHUB_TOKEN=... GITHUB_REPO=owner/repo SECRETS_JSON='{"A":"1"}' \
        python gh_secrets.py

El wrapper de PowerShell `set-signing-secrets.ps1` llama a esto por ti.
"""

import base64
import json
import os
import sys
import urllib.request

from nacl import encoding, public

API = "https://api.github.com"


def _api(method: str, url: str, token: str, payload: dict | None = None):
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(url, data=body, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("User-Agent", "VibeGrab-Secrets")
    if body is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request) as response:
        raw = response.read().decode("utf-8")
        return json.loads(raw) if raw else {}


def set_secrets(repo: str, token: str, secrets: dict[str, str]) -> None:
    key = _api("GET", f"{API}/repos/{repo}/actions/secrets/public-key", token)
    sealed = public.SealedBox(
        public.PublicKey(key["key"].encode("utf-8"), encoding.Base64Encoder())
    )
    for name, value in secrets.items():
        encrypted = base64.b64encode(sealed.encrypt(value.encode("utf-8"))).decode()
        _api(
            "PUT",
            f"{API}/repos/{repo}/actions/secrets/{name}",
            token,
            {"encrypted_value": encrypted, "key_id": key["key_id"]},
        )
        print(f"  OK  {name}")


def main() -> int:
    token = os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("GITHUB_REPO")
    raw = os.environ.get("SECRETS_JSON")
    if not token or not repo or not raw:
        print("Faltan GITHUB_TOKEN, GITHUB_REPO o SECRETS_JSON", file=sys.stderr)
        return 2
    secrets = json.loads(raw)
    print(f"Configurando {len(secrets)} secreto(s) en {repo} ...")
    set_secrets(repo, token, secrets)
    print("Hecho.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
