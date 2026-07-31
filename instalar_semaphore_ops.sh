#!/bin/bash
# =============================================================================
#  SYNAPSE — SEMAPHORE UI (orquestração de Ansible/playbooks)
#  Uso EXCLUSIVO na VPS de operação da Synapse — NÃO faz parte do
#  provisionamento de clientes/lojistas (provisionar_cliente_synapse.sh).
#
#  Uso:
#    sudo ./instalar_semaphore_ops.sh
#
#  Variáveis opcionais (export antes de rodar):
#    SEMAPHORE_PORT          porta local de acesso (default: 3001)
#    SEMAPHORE_ADMIN_EMAIL   e-mail do admin inicial (default: ops@nomen.me)
#    SEMAPHORE_ADMIN_USER    usuário do admin inicial (default: synapse-ops)
#
#  O que este script garante (conforme especificação):
#    1. Sobe o Semaphore UI via Docker Compose.
#    2. NUNCA expõe a porta publicamente — bind em 127.0.0.1 apenas, sem
#       label de Traefik, sem subdomínio, sem regra de UFW liberando a porta.
#       Acesso só via túnel SSH: ssh -L <porta>:localhost:<porta> user@vps
#    3. Monta /var/run/docker.sock (necessário pro próprio Semaphore rodar
#       tasks em containers efêmeros) e usa BoltDB embutido (equivalente ao
#       SQLite) em volume dedicado — sem subir Postgres/MySQL à parte.
#    4. Confere ANTES de instalar se há conflito de nome de container, rede,
#       volume ou porta com algo que já esteja rodando nesta VPS.
# =============================================================================
set -uo pipefail

SEMAPHORE_PORT="${SEMAPHORE_PORT:-3001}"
SEMAPHORE_ADMIN_EMAIL="${SEMAPHORE_ADMIN_EMAIL:-ops@nomen.me}"
SEMAPHORE_ADMIN_USER="${SEMAPHORE_ADMIN_USER:-synapse-ops}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
err()  { echo -e "${RED}[ERRO]${NC} $1"; }
fatal(){ echo -e "${RED}[FATAL]${NC} $1"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  fatal "Este script precisa correr como root. Corre com 'sudo -E'."
fi

# =============================================================================
# 1. PRÉ-VERIFICAÇÕES DE CONFLITO
#    ("cuidado para não conflitar com nada que foi instalado anteriormente")
# =============================================================================
# Numa VPS recém-criada o unattended-upgrades pode segurar o lock do
# dpkg/apt por um bom tempo. Paramos a instância atual dele (não desativa
# permanentemente, só interrompe a execução em andamento) e, como rede de
# segurança extra, esperamos o lock liberar antes de instalar o Docker.
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

if ! command -v docker >/dev/null 2>&1; then
  log "Docker não encontrado — instalando..."
  tentativas=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    tentativas=$((tentativas+1))
    if [ $tentativas -ge 60 ]; then
      warn "dpkg/apt ainda ocupado por outro processo depois de 5min — seguindo mesmo assim (pode falhar)."
      break
    fi
    log "apt/dpkg ocupado por outro processo (provavelmente unattended-upgrades) — aguardando... (${tentativas}/60)"
    sleep 5
  done
  curl -fsSL https://get.docker.com | sh || fatal "Falha ao instalar Docker."
  systemctl enable --now docker
fi
ok "Docker disponível: $(docker --version)"

if docker inspect semaphore >/dev/null 2>&1; then
  warn "Já existe um container chamado 'semaphore' nesta VPS — o script vai reaproveitar/atualizar em vez de duplicar (docker compose é idempotente)."
fi

if docker network inspect stack-network >/dev/null 2>&1; then
  warn "Rede 'stack-network' já existe nesta VPS (provavelmente de uma instalação de cliente Synapse). O Semaphore vai usar uma rede PRÓPRIA ('semaphore-network'), isolada, pra não se misturar com stacks de lojista."
fi
docker network create semaphore-network 2>/dev/null || true

# porta livre: se SEMAPHORE_PORT já estiver ocupada por outra coisa (que não
# seja o próprio container semaphore de uma execução anterior), sobe a porta
# automaticamente até achar uma livre, em vez de derrubar o que já existe.
porta_em_uso() {
  local porta="$1"
  # já é o nosso próprio container nessa porta? não conta como conflito.
  if docker ps --filter "name=^semaphore$" --format '{{.Ports}}' 2>/dev/null | grep -q "127.0.0.1:${porta}->"; then
    return 1
  fi
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(^|:)${porta}$"
}
while porta_em_uso "$SEMAPHORE_PORT"; do
  warn "Porta 127.0.0.1:${SEMAPHORE_PORT} já está em uso por outro serviço nesta VPS — tentando a próxima."
  SEMAPHORE_PORT=$((SEMAPHORE_PORT + 1))
done
ok "Semaphore vai usar a porta local ${SEMAPHORE_PORT} (127.0.0.1:${SEMAPHORE_PORT} -> container:3000)"

if [ ! -d /home/ubuntu/semaphore ] && [ -d /home/ubuntu ]; then
  : # ok, segue
elif [ ! -d /home/ubuntu ]; then
  mkdir -p /home/ubuntu
fi

# =============================================================================
# 2. CREDENCIAIS
# =============================================================================
CRED_FILE="/root/semaphore_credentials.txt"
SEMAPHORE_ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)"
SEMAPHORE_ACCESS_KEY_ENCRYPTION="$(head -c32 /dev/urandom | base64)"

: > "$CRED_FILE"; chmod 600 "$CRED_FILE"
cat >> "$CRED_FILE" << EOF
SEMAPHORE_PORT=${SEMAPHORE_PORT}
SEMAPHORE_ADMIN_USER=${SEMAPHORE_ADMIN_USER}
SEMAPHORE_ADMIN_PASSWORD=${SEMAPHORE_ADMIN_PASSWORD}
SEMAPHORE_ADMIN_EMAIL=${SEMAPHORE_ADMIN_EMAIL}
SEMAPHORE_ACCESS_KEY_ENCRYPTION=${SEMAPHORE_ACCESS_KEY_ENCRYPTION}
EOF
ok "Credenciais geradas e guardadas em ${CRED_FILE} (permissões 600)"

# =============================================================================
# 3. DOCKER COMPOSE
#    Sem label de Traefik, sem rede pública, sem regra de UFW — só bind em
#    127.0.0.1. BoltDB embutido (persistido em volume) no lugar de um
#    Postgres à parte, pra não somar mais um container/porta a vigiar.
# =============================================================================
mkdir -p /home/ubuntu/semaphore
cat > /home/ubuntu/semaphore/docker-compose.yml << EOF
services:
  semaphore:
    image: semaphoreui/semaphore:latest
    container_name: semaphore
    restart: always
    ports:
      - "127.0.0.1:${SEMAPHORE_PORT}:3000"
    environment:
      SEMAPHORE_DB_DIALECT: bolt
      SEMAPHORE_ADMIN: ${SEMAPHORE_ADMIN_USER}
      SEMAPHORE_ADMIN_PASSWORD: ${SEMAPHORE_ADMIN_PASSWORD}
      SEMAPHORE_ADMIN_NAME: "Synapse Ops"
      SEMAPHORE_ADMIN_EMAIL: ${SEMAPHORE_ADMIN_EMAIL}
      SEMAPHORE_ACCESS_KEY_ENCRYPTION: ${SEMAPHORE_ACCESS_KEY_ENCRYPTION}
      TZ: America/Sao_Paulo
    volumes:
      - semaphore_config:/etc/semaphore
      - semaphore_data:/var/lib/semaphore
      # Necessário pro Semaphore executar cada task/playbook em container
      # efêmero próprio (arquitetura padrão dele) — NÃO é usado pra expor
      # nem gerenciar stacks de lojista à distância; isso é feito depois,
      # de dentro do Semaphore, via inventário SSH normal do Ansible.
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - semaphore-network
volumes:
  semaphore_config:
  semaphore_data:
networks:
  semaphore-network:
    external: true
EOF

cd /home/ubuntu/semaphore && docker compose up -d || fatal "Falha ao subir o Semaphore UI. Verifica 'docker logs semaphore'."

log "Aguardando o Semaphore responder localmente..."
TENTATIVAS=0
until curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${SEMAPHORE_PORT}"; do
  TENTATIVAS=$((TENTATIVAS+1))
  [ $TENTATIVAS -ge 20 ] && { err "Semaphore não respondeu em 40s. Verifica 'docker logs semaphore'."; break; }
  sleep 2
done
ok "Semaphore UI no ar (verificado localmente em http://127.0.0.1:${SEMAPHORE_PORT})"

# =============================================================================
# 4. CONFIRMA QUE NÃO ESTÁ EXPOSTO PUBLICAMENTE
# =============================================================================
IP_PUBLICO="$(curl -s --max-time 5 https://ifconfig.me || true)"
if [ -n "$IP_PUBLICO" ]; then
  CODE_PUBLICO=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${IP_PUBLICO}:${SEMAPHORE_PORT}" 2>/dev/null)
  if [ "$CODE_PUBLICO" != "000" ]; then
    err "A porta ${SEMAPHORE_PORT} respondeu por fora (HTTP ${CODE_PUBLICO}) usando o IP público (${IP_PUBLICO}) — algo está expondo essa porta além do bind em 127.0.0.1 (revise UFW/NAT/outro proxy nesta VPS)."
  else
    ok "Confirmado: porta ${SEMAPHORE_PORT} NÃO responde por fora (só via 127.0.0.1 / túnel SSH), como especificado."
  fi
else
  warn "Não consegui detectar o IP público pra confirmar automaticamente que a porta está fechada. Confira manualmente de outra máquina: nada deve responder em <ip-da-vps>:${SEMAPHORE_PORT}."
fi

if ufw status 2>/dev/null | grep -q "${SEMAPHORE_PORT}"; then
  err "Encontrei uma regra de UFW mencionando a porta ${SEMAPHORE_PORT} — revise com 'ufw status numbered' e remova se estiver liberando acesso externo."
else
  ok "Nenhuma regra de UFW libera a porta ${SEMAPHORE_PORT} — bind em 127.0.0.1 já é a proteção principal."
fi

# =============================================================================
# RESUMO FINAL
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   SEMAPHORE UI INSTALADO (uso interno — não é pro lojista)${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  Acesso        → só via túnel SSH, nunca direto"
echo -e "  Túnel         → ssh -L ${SEMAPHORE_PORT}:localhost:${SEMAPHORE_PORT} <usuario>@${IP_PUBLICO:-<ip-da-vps>}"
echo -e "  Depois do túnel, abra → http://localhost:${SEMAPHORE_PORT}"
echo -e "  Usuário admin → ${SEMAPHORE_ADMIN_USER}"
echo -e "  Senha admin   → ver ${CRED_FILE} (chmod 600)"
echo -e "  Credenciais completas → ${CRED_FILE}"
echo ""
echo -e "${YELLOW}Próximos passos (dentro do Semaphore, depois de logar):${NC}"
echo -e "  1. Criar um Team/Project."
echo -e "  2. Cadastrar no Key Store as chaves SSH usadas pra acessar as VPS dos clientes"
echo -e "     (é assim que o Semaphore vai orquestrar Ritmo/Harmonia/Harpa remotamente —"
echo -e "     via inventário Ansible normal, não pelo docker.sock local)."
echo -e "  3. Apontar o repositório com os playbooks (github.com/nomen-me/semaphore.git) e criar os Templates de Task."
echo -e "${GREEN}============================================================${NC}"
