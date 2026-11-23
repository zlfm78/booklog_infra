#!/usr/bin/env bash
# 노드 상태 · IP 확인 + WSL ~/.ssh/config.d/booklog 갱신 (ssh cp / worker1 / worker2 로 접속)
# 공인 IP는 시작할 때마다 바뀌므로 start.sh 뒤에 다시 실행한다
set -euo pipefail
source "$(dirname "$0")/env.sh"

aws ec2 describe-instances --filters Name=tag:Project,Values=$PROJECT Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,State.Name,InstanceType,PrivateIpAddress,PublicIpAddress,CpuOptions.CoreCount,Placement.AvailabilityZone]' \
  --output text | sort | awk 'BEGIN{printf "%-16s %-20s %-8s %-11s %-11s %-15s %s\n","NAME","ID","STATE","TYPE","PRIVATE","PUBLIC","AZ"} {printf "%-16s %-20s %-8s %-11s %-11s %-15s %s\n",$1,$2,$3,$4,$5,$6,$8}'

mkdir -p ~/.ssh/config.d && chmod 700 ~/.ssh ~/.ssh/config.d
grep -qs '^Include config.d/\*' ~/.ssh/config || { printf 'Include config.d/*\n\n' | cat - ~/.ssh/config 2>/dev/null > ~/.ssh/config.new || true; mv ~/.ssh/config.new ~/.ssh/config; chmod 600 ~/.ssh/config; }
CONF=~/.ssh/config.d/booklog; : > "$CONF"
for n in "${NODES[@]}"; do
  read -r NAME IP ROLE <<<"$n"
  PUB=$(aws ec2 describe-instances --filters Name=tag:Project,Values=$PROJECT Name=tag:Name,Values=$PROJECT-$NAME Name=instance-state-name,Values=running \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  [ "$PUB" = "None" ] && continue
  # HostKeyAlias: 공인 IP가 바뀌어도 호스트 키를 노드 이름으로 기억
  printf 'Host %s\n  HostName %s\n  User %s\n  IdentityFile %s\n  HostKeyAlias booklog-%s\n  StrictHostKeyChecking accept-new\n  UserKnownHostsFile ~/.ssh/known_hosts.booklog\n\n' "$NAME" "$PUB" "$SSH_USER" "$KEY_FILE" "$NAME" >> "$CONF"
done
chmod 600 "$CONF"
echo "ssh 설정 갱신: $CONF ($(grep -c '^Host ' "$CONF")대)"
