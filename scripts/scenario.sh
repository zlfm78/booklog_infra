#!/usr/bin/env bash
# booklog 공통 테스트 시나리오 (① 로컬 → ② Docker → ③ K8s → ④ EKS 모두 같은 스크립트로 확인)
#   scripts/scenario.sh <BASE_URL> write     # S1~S11 실행, verify가 볼 값을 scenario-state.json에 저장
#   scripts/scenario.sh <BASE_URL> verify    # S12~S13: 재시작·컨테이너/Pod 교체 후 write가 만든 데이터가 남아 있는지 확인
# BASE_URL은 web 주소 (예: ① http://localhost:4173 = 빌드 결과물을 vite preview로). /api/*는 web이 was로 넘긴다.
# verify는 데모 계정 확인에 DEMO_PASSWORD 환경 변수가 필요하다 (.env를 export).
set -u

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "$cmd 가 필요합니다: sudo apt install -y $cmd"; exit 2; }
done
if [ $# -lt 2 ] || { [ "$2" != write ] && [ "$2" != verify ]; }; then
  echo "사용: $0 <BASE_URL> write|verify   예) $0 http://localhost:4173 write"; exit 2
fi
BASE="${1%/}"
MODE="$2"
DIR="$(cd "$(dirname "$0")/.." && pwd)"          # booklog_infra
STATE="${STATE_FILE:-$DIR/scenario-state.json}"   # .gitignore 대상 (테스트 계정 비밀번호 포함)
PASS=0; FAIL=0
STAMP="$(date +%m%d%H%M%S)"
DAY1=2026-01-01; DAY2=2026-01-02; PAGES=300       # 시나리오 책
DEMO_USER="demo"; DEMO_BOOKS=10                   # booklog_was/seed/catalog.yaml 기준
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ME="$TMP/me.jar"; OTHER="$TMP/other.jar"; NONE="$TMP/none.jar"; DEMO="$TMP/demo.jar"   # 쿠키 파일 = 브라우저의 쿠키 저장소
JAR="$NONE"

check() { # 이름, 기대, 실제
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  [PASS] %-36s 기대=%s 실제=%s\n' "$1" "$2" "$3"
  else FAIL=$((FAIL+1)); printf '  [FAIL] %-36s 기대=%s 실제=%s\n' "$1" "$2" "$3"
       [ -n "${BODY:-}" ] && printf '         응답: %.200s\n' "$BODY"; fi
}
req() { # METHOD PATH [BODY] → 상태 코드 $CODE, 본문 $BODY, 헤더 $TMP/headers. 쿠키는 $JAR로 보내고 받는다
  local args=(-s -o "$TMP/body" -D "$TMP/headers" -w '%{http_code}' -X "$1" -b "$JAR" -c "$JAR")
  [ -n "${3:-}" ] && args+=(-H 'Content-Type: application/json' -d "$3")
  rm -f "$TMP/body"; CODE="$(curl "${args[@]}" "$BASE$2")"; BODY="$(cat "$TMP/body" 2>/dev/null)"
}
j() { echo "$BODY" | jq -r "$1" 2>/dev/null; }                 # 응답 본문에서 값 꺼내기
s() { jq -r "$1" "$STATE"; }                                   # write가 남긴 값 꺼내기 (verify)
pw() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }        # 테스트용 무작위 비밀번호
signup() { jq -nc --arg u "$1" --arg p "$2" --arg e "$3" '{username:$u,password:$p,name:"시나리오",nickname:"테스터",email:$e}'; }
login()  { jq -nc --arg u "$1" --arg p "$2" '{username:$u,password:$p}'; }
logjs()  { jq -nc --argjson p "$1" --arg n "$2" '{page:$p,note:$n}'; }

echo "BASE_URL=$BASE  MODE=$MODE  $(date '+%F %T %Z')"

if [ "$MODE" = "verify" ]; then
  [ -f "$STATE" ] || { echo "state 파일이 없습니다: $STATE (먼저 write 실행)"; exit 1; }
  : "${DEMO_PASSWORD:?DEMO_PASSWORD 환경 변수가 필요합니다 (.env를 export)}"
  JAR="$ME"
  req GET "/api/info"; echo "  응답 was Pod=$(j .pod) 노드=$(j .node) 버전=$(j .version)"

  echo "S12 데이터 유지 (아이디=$(s .username), 책 ID=$(s .id))"
  req POST "/api/auth/login" "$(login "$(s .username)" "$(s .password)")"
  check "바꾼 비밀번호로 다시 로그인" 200 "$CODE"
  req GET "/api/auth/me"
  check "수정한 닉네임 유지" "$(s .nickname)" "$(j .nickname)"
  check "수정한 이메일 유지" "$(s .email)" "$(j .email)"
  req GET "/api/books/$(s .id)"
  check "책 조회" 200 "$CODE"
  check "제목 유지" "$(s .title)" "$(j .title)"
  check "기록 수 유지" "$(s .log_count)" "$(j '.logs|length')"
  check "마지막 쪽 유지" "$(s .last_page)" "$(j .progress.page)"
  check "독서 상태 유지" "$(s .status)" "$(j .status)"
  check "평점 유지" "$(s .rating)" "$(j .rating)"
  check "독후감 유지" "$(s .review)" "$(j .review)"
  check "updated_at 유지 (수정 없음)" "$(s .updated_at)" "$(j .updated_at)"

  echo "S13 초기 데이터 (시드)"
  JAR="$DEMO"
  req POST "/api/auth/login" "$(login "$DEMO_USER" "$DEMO_PASSWORD")"
  check "데모 계정 로그인" 200 "$CODE"
  req GET "/api/books"
  check "데모 계정의 책 ${DEMO_BOOKS}권 이상" true "$(j ".total >= $DEMO_BOOKS")"

  echo "결과: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ]; exit
fi

echo "S1 화면·상태"
req GET "/";                 check "web 첫 화면 /" 200 "$CODE"
req GET "/api/health/ready"; check "was readiness (DB 연결)" ok "$(j .status)"
req GET "/api/info";         check "서버 정보 /api/info" 200 "$CODE"
echo "  응답 was Pod=$(j .pod) 노드=$(j .node) 버전=$(j .version)"

echo "S2 로그인 필요"
req GET "/api/books";        check "로그인 없이 내 책 목록" 401 "$CODE"

echo "S3 회원 가입"
MY_ID="s${STAMP}_$RANDOM"; EMAIL="scenario-$STAMP@example.com"; PW="$(pw)"
req POST "/api/auth/register" "$(signup "$MY_ID" "$PW" "$EMAIL")";      check "가입 ($MY_ID)" 201 "$CODE"
req POST "/api/auth/register" "$(signup "$MY_ID" "$PW" "x-$EMAIL")";    check "같은 아이디로 다시 가입" 409 "$CODE"
req POST "/api/auth/register" "$(signup "${MY_ID}x" "$PW" "$EMAIL")";   check "같은 이메일로 다시 가입" 409 "$CODE"

echo "S4 로그인·내 정보"
JAR="$ME"
req POST "/api/auth/login" "$(login "$MY_ID" "$PW")";                   check "아이디로 로그인" 200 "$CODE"
check "로그인 쿠키 HttpOnly" yes "$(grep -qiE '^set-cookie: access_token=.*httponly' "$TMP/headers" && echo yes || echo no)"
req GET "/api/auth/me";                                                check "내 정보 조회" 200 "$CODE"
check "내 아이디 일치" "$MY_ID" "$(j .username)"
check "응답에 비밀번호 해시 없음" false "$(j 'has("password_hash")')"

echo "S5 회원 수정"
NICK="책읽는사람"; EMAIL2="scenario-$STAMP-new@example.com"
req PATCH "/api/auth/me" "$(jq -nc --arg n "$NICK" --arg e "$EMAIL2" '{nickname:$n,email:$e}')"
check "정보 수정 응답" 200 "$CODE"
check "닉네임·이메일 반영" "$NICK/$EMAIL2" "$(j '.nickname + "/" + .email')"
PW2="$(pw)"
req PUT "/api/auth/me/password" "$(jq -nc --arg n "$PW2" '{current_password:"wrong-password",new_password:$n}')"
check "비밀번호 변경: 현재 비밀번호 틀림" 401 "$CODE"
req PUT "/api/auth/me/password" "$(jq -nc --arg c "$PW" --arg n "$PW2" '{current_password:$c,new_password:$n}')"
check "비밀번호 변경" 204 "$CODE"
req POST "/api/auth/login" "$(login "$MY_ID" "$PW2")";                  check "새 비밀번호로 로그인" 200 "$CODE"
JAR="$NONE"; req POST "/api/auth/login" "$(login "$MY_ID" "$PW")";      check "예전 비밀번호로 로그인" 401 "$CODE"
JAR="$ME"; PW="$PW2"

echo "S6 책 등록·조회"
TITLE="시나리오 책 $STAMP"
req POST "/api/books" "$(jq -nc --arg t "$TITLE" --argjson n "$PAGES" '{title:$t,author:"scenario",total_pages:$n}')"
check "책 등록 (${PAGES}쪽)" 201 "$CODE"
check "처음 상태" unread "$(j .status)"
BOOK="$(j .id)"; echo "  책 ID=$BOOK"
req GET "/api/books";                       check "내 책 목록" 200 "$CODE"
check "내 목록 = 방금 등록한 책 1권" "1/$BOOK" "$(j '"\(.total)/\(.items[0].id)"')"
req GET "/api/books?q=$STAMP";              check "제목 검색 → 1권" 1 "$(j .total)"

echo "S7 날짜별 독서 기록"
req PUT "/api/books/$BOOK/logs/$DAY1" "$(logjs 50 '1장')";     check "기록 $DAY1 50쪽" 200 "$CODE"
check "첫 기록 → 상태 자동 변경" reading "$(j .status)"
req PUT "/api/books/$BOOK/logs/$DAY2" "$(logjs 120 '3장')";    check "기록 $DAY2 120쪽" 200 "$CODE"
check "기록 수/진행 쪽/진행률" "2/120/40" "$(j '"\(.logs|length)/\(.progress.page)/\(.progress.percent)"')"
req PUT "/api/books/$BOOK/logs/$DAY2" "$(logjs 150 '덮어쓰기')"; check "같은 날짜 재기록 150쪽" 200 "$CODE"
check "덮어쓰기 (기록 수 그대로)" "2/150/덮어쓰기" "$(j '"\(.logs|length)/\(.progress.page)/\(.logs[0].note)"')"
req PUT "/api/books/$BOOK/logs/$DAY2" "$(logjs 999 x)";        check "전체 쪽수 초과 기록 거부" 422 "$CODE"
req GET "/api/books/$BOOK/logs";                               check "기록 목록 (최근 날짜순)" "$DAY2,$DAY1" "$(j '[.[].read_on]|join(",")')"

echo "S8 평점·독후감·상태 필터"
REVIEW="시나리오 독후감 $STAMP"
req PATCH "/api/books/$BOOK" "$(jq -nc --arg r "$REVIEW" '{rating:5,review:$r}')"
check "평점·독후감 저장" 200 "$CODE"
check "평점/독후감 반영" "5/$REVIEW" "$(j '"\(.rating)/\(.review)"')"
UPDATED="$(j .updated_at)"
req GET "/api/books?status=reading";        check "상태 필터 reading → 포함" true "$(j "any(.items[]; .id == $BOOK)")"
req GET "/api/books?status=done";           check "상태 필터 done → 없음" 0 "$(j .total)"

echo "S9 다른 사용자 차단"
OTHER_ID="${MY_ID}_o"; PW_O="$(pw)"
req POST "/api/auth/register" "$(signup "$OTHER_ID" "$PW_O" "scenario-$STAMP-other@example.com")"
check "다른 계정 가입" 201 "$CODE"
JAR="$OTHER"
req POST "/api/auth/login" "$(login "$OTHER_ID" "$PW_O")";       check "다른 계정 로그인" 200 "$CODE"
req GET "/api/books/$BOOK";                                    check "남의 책 조회" 404 "$CODE"
req GET "/api/books/$BOOK/logs";                               check "남의 책 기록 조회" 404 "$CODE"
req PUT "/api/books/$BOOK/logs/$DAY1" "$(logjs 1 x)";          check "남의 책에 기록" 404 "$CODE"

echo "S10 삭제 (임시 책으로, verify가 볼 데이터는 건드리지 않음)"
JAR="$ME"
req POST "/api/books" "$(jq -nc --arg t "시나리오 임시 책 $STAMP" '{title:$t,author:"scenario",total_pages:100}')"
check "임시 책 등록" 201 "$CODE"; TMPBOOK="$(j .id)"
req PUT "/api/books/$TMPBOOK/logs/$DAY1" "$(logjs 10 a)"
req PUT "/api/books/$TMPBOOK/logs/$DAY2" "$(logjs 20 b)";      check "임시 책 기록 수" 2 "$(j '.logs|length')"
req DELETE "/api/books/$TMPBOOK/logs/$DAY2";                   check "기록 1개 삭제" 200 "$CODE"
check "남은 기록/진행 쪽/상태 (상태는 유지)" "1/10/reading" "$(j '"\(.logs|length)/\(.progress.page)/\(.status)"')"
req DELETE "/api/books/$TMPBOOK/logs/$DAY2";                   check "없는 날짜 기록 삭제" 404 "$CODE"
req DELETE "/api/books/$TMPBOOK";                              check "기록이 있는 책 삭제 (CASCADE)" 204 "$CODE"
req GET "/api/books/$TMPBOOK";                                 check "삭제한 책 조회" 404 "$CODE"
req GET "/api/books/$TMPBOOK/logs";                            check "삭제한 책의 기록 조회" 404 "$CODE"

echo "S11 회원 탈퇴 (다른 계정으로)"
JAR="$OTHER"; cp "$OTHER" "$TMP/other-old.jar"     # 탈퇴하면 쿠키가 지워지므로 이전 쿠키 보관
req DELETE "/api/auth/me" '{"password":"wrong-password"}';    check "탈퇴: 비밀번호 틀림" 401 "$CODE"
req DELETE "/api/auth/me" "$(jq -nc --arg p "$PW_O" '{password:$p}')"; check "탈퇴" 204 "$CODE"
JAR="$TMP/other-old.jar"; req GET "/api/books";                check "탈퇴한 계정의 이전 쿠키" 401 "$CODE"
JAR="$NONE"; req POST "/api/auth/login" "$(login "$OTHER_ID" "$PW_O")"; check "탈퇴한 계정 재로그인" 401 "$CODE"

# verify가 비교할 값 (비밀번호는 바꾼 새 비밀번호). 실패가 있으면 저장하지 않는다: 반쯤 만들어진 데이터와 비교하지 않도록
if [ "$FAIL" -eq 0 ]; then
  jq -n --arg u "$MY_ID" --arg p "$PW" --arg n "$NICK" --arg e "$EMAIL2" --argjson id "$BOOK" \
      --arg t "$TITLE" --arg r "$REVIEW" --arg up "$UPDATED" \
  '{username:$u,password:$p,nickname:$n,email:$e,id:$id,title:$t,log_count:2,last_page:150,
    status:"reading",rating:5,review:$r,updated_at:$up}' > "$STATE"
  echo "  state 저장: $STATE (아이디=$MY_ID, 책 ID=$BOOK)"
else
  echo "  실패 항목이 있어 state 파일을 저장하지 않음 (이전 파일 유지)"
fi

echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
