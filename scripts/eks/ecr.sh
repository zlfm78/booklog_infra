#!/usr/bin/env bash
# ④ ECR: 저장소 만들기 → Docker Hub 이미지를 같은 다이제스트로 복사(재빌드 안 함) → 덮어쓰기 거부 확인
#   태그 IMMUTABLE(예외 없음) · scan on push(기본 스캔) · 암호화 AES-256(기본값, 생성 후 변경 불가)
# 사용: scripts/eks/ecr.sh
set -euo pipefail
source "$(dirname "$0")/env.sh"
REG=$(registry)
# 중간에 실패해도 ECR 토큰을 ~/.docker/config.json에 남기지 않게
trap 'docker logout "$REG" >/dev/null 2>&1 && echo "docker logout (자격 증명 파일에서 ECR 토큰 제거)"' EXIT

echo "== 저장소"
for r in "${ECR_REPOS[@]}"; do
  if aws ecr describe-repositories --repository-names "$r" >/dev/null 2>&1; then
    echo "$r 이미 있음"
  else
    aws ecr create-repository --repository-name "$r" \
      --image-tag-mutability IMMUTABLE \
      --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=AES256 \
      --tags Key=Project,Value=$PROJECT >/dev/null
    echo "$r 생성"
  fi
done
aws ecr describe-repositories --repository-names "${ECR_REPOS[@]}" \
  --query 'repositories[].[repositoryName,imageTagMutability,imageScanningConfiguration.scanOnPush,encryptionConfiguration.encryptionType]' --output table | mask

echo "== 로그인 (토큰은 표준 입력으로만 전달)"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REG" 2>&1 | mask

echo "== 복사: docker buildx imagetools create (원본 매니페스트를 그대로 push → 다이제스트 같음)"
for i in "${IMAGES[@]}"; do
  read -r NAME TAG <<<"$i"
  SRC=docker.io/$DOCKERHUB/$NAME:$TAG
  if aws ecr describe-images --repository-name "$NAME" --image-ids imageTag="$TAG" >/dev/null 2>&1; then
    echo "$NAME:$TAG 이미 있음 (건너뜀)"
  else
    docker buildx imagetools create --tag "$REG/$NAME:$TAG" "$SRC" 2>&1 | mask | tail -2
  fi
  SRC_D=$(docker buildx imagetools inspect "$SRC" --format '{{json .Manifest.Digest}}' | tr -d '"')
  ECR_D=$(aws ecr describe-images --repository-name "$NAME" --image-ids imageTag="$TAG" --query 'imageDetails[0].imageDigest' --output text)
  printf '%-12s %-6s Docker Hub %s\n%-12s %-6s ECR        %s  %s\n' "$NAME" "$TAG" "$SRC_D" "" "" "$ECR_D" "$([ "$SRC_D" = "$ECR_D" ] && echo 같음 || echo 다름)"
done

echo "== 덮어쓰기 거부 확인"
read -r NAME TAG <<<"${IMAGES[0]}"
read -r _ OTHER <<<"${IMAGES[1]}"
echo "-- (가) 같은 이미지(같은 다이제스트)를 같은 태그 $NAME:$TAG 로 다시 push: 내용이 같아 바뀌는 것 없음"
docker buildx imagetools create --tag "$REG/$NAME:$TAG" "docker.io/$DOCKERHUB/$NAME:$TAG" 2>&1 | mask | tail -1 || true
echo "-- (나) 다른 이미지($NAME:$OTHER)를 이미 있는 태그 $NAME:$TAG 로 push: IMMUTABLE이면 거부돼야 정상"
docker buildx imagetools create --tag "$REG/$NAME:$TAG" "docker.io/$DOCKERHUB/$NAME:$OTHER" 2>&1 | mask | tail -3 || true
echo "-- 태그 $NAME:$TAG 의 다이제스트 (위 Docker Hub 값과 같아야 함 = 덮어써지지 않음)"
aws ecr describe-images --repository-name "$NAME" --image-ids imageTag="$TAG" --query 'imageDetails[0].imageDigest' --output text

echo "== 스캔 결과 (기본 스캔, scan on push)"
echo "   태그는 이미지 인덱스(플랫폼 목록)를 가리키므로 실제 이미지인 linux/amd64 매니페스트 다이제스트로 조회"
for i in "${IMAGES[@]}"; do
  read -r NAME TAG <<<"$i"
  D=$(docker buildx imagetools inspect "docker.io/$DOCKERHUB/$NAME:$TAG" --raw \
      | jq -r '.manifests[]? | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest' | head -1)
  printf '%-12s %-6s amd64 %s  ' "$NAME" "$TAG" "${D:0:19}"
  aws ecr describe-image-scan-findings --repository-name "$NAME" --image-id imageDigest="$D" \
    --query '[imageScanStatus.status, imageScanFindings.findingSeverityCounts]' --output json 2>&1 | tr -d '\n ' | mask || true
  echo
done
