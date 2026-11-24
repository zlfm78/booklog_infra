# booklog_infra

**booklog**(개인 서재 · 독서 기록장)를 실행 · 배포하는 구성과 테스트 시나리오, 문서를 담은 **설정 저장소**입니다.
컨테이너 · Kubernetes 인프라 구축 개인 캡스톤으로, 같은 워크로드를 단계별로 옮깁니다.

**① WSL 2 Ubuntu → ② Docker → ③ EC2 kubeadm 클러스터 → ④ Amazon EKS(Auto Mode)**

| 저장소 | 역할 |
|---|---|
| [booklog_was](https://github.com/zlfm78/booklog_was) | API 서버(FastAPI) → 이미지 `booklog-was` |
| [booklog_web](https://github.com/zlfm78/booklog_web) | 화면(React) → 이미지 `booklog-web` |
| **booklog_infra** (이 저장소) | 어떤 버전 조합을 어떻게 실행 · 배포하는지 |

소스와 배포 설정을 나눈 이유: 설정만 바꿀 때 이미지를 다시 빌드하지 않고, 배포 이력이 개발 커밋과 섞이지 않으며, 버전이 따로인 web · was를 한 단위로 배포하기 위해서입니다 (Argo CD Best Practices, "Separating Config Vs. Source Code Repositories").

## 구성

```
.env.example        환경 변수 키 목록 (값 없음). cp .env.example .env 후 채움 — .env는 커밋하지 않음
compose.yaml        ② db · migrate · was · web (IMAGE_PREFIX=jeonghyeonseong/ 이면 Docker Hub 이미지)
scripts/
├── scenario.sh     모든 단계 공통 테스트 시나리오 (write · verify)
├── aws/            ③ EC2 kubeadm 클러스터용 AWS 자원 (태그 Project=booklog)
├── k8s/            ③ 노드 준비 · Secret · SSH 터널
└── eks/            ④ EKS Auto Mode: ecr.sh → create.sh → rds.sh(RDS Multi-AZ · Proxy · Secrets Manager · CSI) → deploy.sh, status.sh · delete.sh (태그 Project=booklog-eks)
k8s/                ③부터: Kustomize base + overlays/ec2, overlays/eks
├── cluster/        ③ 클러스터 구성 요소 (kubeadm 설정 · Calico · local-path · metrics-server)
└── cluster-eks/    ④ NodeClass · NodePool · StorageClass · IngressClass · NetworkPolicy 컨트롤러
```

단계별 실행 절차 · 결과 · 화면은 제출 문서(Notion)에 정리하고, 이 저장소에는 실행 · 배포에 필요한 파일만 둡니다.

## 테스트 시나리오

```bash
cd ~/booklog/booklog_infra && set -a && . ./.env && set +a
scripts/scenario.sh <BASE_URL> write    # S1~S11: 가입 · 로그인 · 책 · 날짜별 기록 · 독후감 · 권한 · 삭제 · 탈퇴 (52개 확인)
scripts/scenario.sh <BASE_URL> verify   # S12~S13: 재시작 · 교체 뒤 write의 데이터가 그대로인지 (13개 확인)
```

- `BASE_URL`은 web 주소입니다(① `http://localhost:4173`). 모든 단계에서 같은 스크립트로 확인합니다.
- 필요 도구: `curl`, `jq`. verify는 `DEMO_PASSWORD` 환경 변수가 필요합니다.
- write는 모든 항목이 통과할 때만 `scenario-state.json`(테스트 계정 비밀번호 포함, 커밋하지 않음)을 저장하고, verify가 그 값과 비교합니다.

## 비밀 값 관리

- 비밀번호 · 키는 `.env`(③④에서는 Secret)로만 주입합니다. `.env`, `scenario-state.json`, `*.secret.yaml`, kubeconfig는 `.gitignore` 대상입니다.
- 커밋할 때마다 gitleaks가 스테이징된 내용을 검사합니다(`.githooks/pre-commit`, 저장소마다 `git config core.hooksPath .githooks`).

## 진행

| 단계 | 상태 |
|---|---|
| ① WSL 2 Ubuntu 테스트 환경 | 완료 (write 52/0, DB 컨테이너 교체 전후 verify 13/0) |
| ② 이미지 빌드 · 컨테이너 테스트 | 완료 — Docker Hub `jeonghyeonseong/booklog-was:1.0.0`, `jeonghyeonseong/booklog-web:1.0.0` (`linux/amd64`), `compose.yaml`로 write 52/0 · verify 13/0 |
| ③ Kubernetes 전환 (EC2 kubeadm) | 진행 예정 |
| ④ EKS 전환 | 진행 예정 |
