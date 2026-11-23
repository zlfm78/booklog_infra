#!/usr/bin/env bash
# 내 공인 IP가 바뀌었을 때(SSH가 응답 없이 멈춤) 보안 그룹의 "my-ip" 규칙(22, web NodePort)을 새 IP로 교체
set -euo pipefail
source "$(dirname "$0")/env.sh"
SG=$(sg_id); MYIP=$(my_ip)
OLD=$(aws ec2 describe-security-groups --group-ids $SG --query 'SecurityGroups[0].IpPermissions[].IpRanges[?starts_with(Description,`my-ip`)].CidrIp' --output text | tr '\t' '\n' | sort -u)
if [ "$OLD" = "$MYIP/32" ]; then echo "변경 없음 ($(echo $MYIP | mask_ip))"; exit 0; fi
for cidr in $OLD; do
  for port in 22 $WEB_NODEPORT; do
    aws ec2 revoke-security-group-ingress --group-id $SG --protocol tcp --port $port --cidr $cidr >/dev/null 2>&1 || true
  done
done
aws ec2 authorize-security-group-ingress --group-id $SG --ip-permissions \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MYIP/32,Description=my-ip SSH}]" \
  "IpProtocol=tcp,FromPort=$WEB_NODEPORT,ToPort=$WEB_NODEPORT,IpRanges=[{CidrIp=$MYIP/32,Description=my-ip web NodePort}]" >/dev/null
echo "my-ip 규칙 교체: $(echo $OLD | mask_ip) → $(echo $MYIP | mask_ip)/32"
