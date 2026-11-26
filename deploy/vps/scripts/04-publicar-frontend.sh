#!/usr/bin/env bash
# Passo 4: compila as telas apontando para a API da VPS e publica em $BASE_DIR/www.
# Cada publicação fica numa pasta própria; voltar a anterior é trocar o link "www".
#   sudo bash /srv/js-lead-hunter/app/deploy/vps/scripts/04-publicar-frontend.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/comum.sh"

ANON_KEY="$(grep '^ANON_KEY=' "$SUPABASE_DIR/.env" | cut -d= -f2-)"
[[ -n "$ANON_KEY" ]] || erro "ANON_KEY não encontrada em $SUPABASE_DIR/.env"

REL="$BASE_DIR/www-versoes/$(date +%Y%m%d-%H%M)"
mkdir -p "$REL"

log "Compilando o frontend (Node 22 em container)"
docker run --rm -v "$APP_DIR/web:/web" -w /web \
  -e VITE_SUPABASE_URL="https://$API_DOMAIN" -e VITE_SUPABASE_ANON_KEY="$ANON_KEY" \
  node:22-alpine sh -c "npm ci --no-audit --no-fund && npm run build"

cp -a "$APP_DIR/web/dist/." "$REL/"
ln -sfn "$REL" "$BASE_DIR/www"
log "Publicado em $REL (link $BASE_DIR/www). Versões anteriores ficam em $BASE_DIR/www-versoes/."
log "A chave publicada é a ANON (pública). A SERVICE_ROLE nunca vai para o frontend."
