#!/usr/bin/env bash
# 엔드포인트의 모델별 온도/추론 파라미터 동작 점검
#
# 사용법:
#   export WS_KEY="sk-..."          # 또는 ~/.ws-env 에 WS_KEY=... 저장
#   ./probe.sh glm-5.2
#   ./probe.sh deepseek-v4-flash-0731
#   WS_RPM=2 ./probe.sh some-model     # 메타데이터에 rpm이 없을 때 수동 지정
#   WS_REPEAT=3 ./probe.sh some-model  # effort 단계마다 3회씩 반복 측정
#   WS_BASE=https://other.example/v1 ./probe.sh some-model
#
# 필요: curl, jq

set -uo pipefail

[ -f ~/.ws-env ] && { set -a; . ~/.ws-env; set +a; }

BASE="${WS_BASE:-https://api.wellspring.encrypt.gay/v1}"
KEY="${WS_KEY:?WS_KEY 환경변수를 설정하세요}"
MODEL="${1:?모델 id를 인자로 주세요}"
MAX_RETRY="${WS_MAX_RETRY:-4}"
REPEAT="${WS_REPEAT:-2}"   # effort 단계마다 반복 측정할 횟수

# 추론 부하가 실제로 걸리는 프롬프트. 가벼운 질문은 effort 단계를 구분 못 함.
PROMPT='세 인물이 있다. A는 B를 배신했지만 B는 모른다. C는 그 사실을 알지만 A에게 빚이 있다. 셋이 한 방에 모이는 장면에서 긴장을 최대로 끌어올릴 대사 순서를 정하고 이유를 설명해.'

# 응답에서 추론 텍스트를 꺼낸다. 프록시마다 필드명이 다르므로 전부 훑는다.
RLEN='(.choices[0].message.reasoning // .choices[0].message.reasoning_content // .choices[0].message.thinking // "") | tostring | length'

# ─────────────────────────────────────────
# 레이트리밋 처리
# ─────────────────────────────────────────
META=$(curl -s "$BASE/models" -H "Authorization: Bearer $KEY" \
  | jq --arg m "$MODEL" '.data[] | select(.id==$m)' 2>/dev/null)

# rpm 필드명은 구현마다 다르므로 후보를 순서대로 본다
RPM="${WS_RPM:-$(echo "$META" | jq -r '
  .rate_limit_rpm // .rpm // .rate_limit // .requests_per_minute //
  .limits.rpm // .rate_limits.rpm // empty' 2>/dev/null)}"

if [ -n "${RPM:-}" ] && [ "$RPM" -gt 0 ] 2>/dev/null; then
  # 60/rpm 에 20% 여유
  INTERVAL=$(awk -v r="$RPM" 'BEGIN{printf "%.1f", 60/r*1.2}')
  echo "  [rate] rpm=$RPM → 요청 간격 ${INTERVAL}초"
else
  RPM=""
  INTERVAL=0
  echo "  [rate] rpm 미확인 → 간격 없음 (WS_RPM=n 으로 수동 지정 가능)"
fi

LAST_CALL=0
throttle() { # 직전 호출로부터 INTERVAL 만큼 벌어질 때까지 대기
  [ "$INTERVAL" = "0" ] && return
  local now wait
  now=$(date +%s.%N)
  wait=$(awk -v n="$now" -v l="$LAST_CALL" -v i="$INTERVAL" \
    'BEGIN{d=i-(n-l); print (d>0)?d:0}')
  awk -v w="$wait" 'BEGIN{exit !(w>0)}' && sleep "$wait"
}

# 호출 + 429 백오프. 성공하면 본문만 stdout으로 낸다.
request() { # $1=body
  local attempt=0 raw code body delay
  while :; do
    throttle
    LAST_CALL=$(date +%s.%N)
    raw=$(curl -s -w $'\n%{http_code}' "$BASE/chat/completions" \
      -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
      -D /tmp/.probe_hdr -d "$1")
    code="${raw##*$'\n'}"
    body="${raw%$'\n'*}"

    if [ "$code" != "429" ]; then
      echo "$body"
      return
    fi

    attempt=$((attempt+1))
    if [ "$attempt" -gt "$MAX_RETRY" ]; then
      echo '{"error":{"message":"429 재시도 초과"}}'
      return
    fi
    # Retry-After 헤더가 있으면 그걸 쓰고, 없으면 지수 백오프
    delay=$(grep -i '^retry-after:' /tmp/.probe_hdr 2>/dev/null \
      | tr -d '\r' | awk '{print $2}' | head -1)
    [ -z "$delay" ] && delay=$(awk -v a="$attempt" 'BEGIN{print 2^a*5}')
    echo "    [429] ${delay}초 대기 후 재시도 ($attempt/$MAX_RETRY)" >&2
    sleep "$delay"
  done
}

call() { # $1=temperature $2=effort("" 이면 미지정)
  local body
  if [ -z "$2" ]; then
    body=$(jq -n --arg m "$MODEL" --arg p "$PROMPT" --argjson t "$1" \
      '{model:$m,messages:[{role:"user",content:$p}],temperature:$t,max_tokens:16000}')
  else
    body=$(jq -n --arg m "$MODEL" --arg p "$PROMPT" --argjson t "$1" --arg e "$2" \
      '{model:$m,messages:[{role:"user",content:$p}],temperature:$t,reasoning_effort:$e,max_tokens:16000}')
  fi
  request "$body"
}

echo "=========================================="
echo " model : $MODEL"
echo " base  : $BASE"
echo "=========================================="

echo
echo "── 0. 모델 메타데이터 ──"
if [ -n "$META" ]; then echo "$META" | jq '.'; else echo "  (조회 실패)"; fi

echo
echo "── 1. reasoning_effort 허용값 캐기 ──"
echo "  쓰레기 값을 넣어 에러 메시지에서 목록을 읽는다"
call 0.7 "__probe__" | jq -r '.error.message // "에러 없음 — 검증을 안 하거나 파라미터가 필터링됨"'

echo
echo "── 2. effort 스윕 (temperature 0.7 고정) ──"
echo "  단계마다 ${REPEAT}회씩 측정. 반복 간 폭보다 단계 간 차이가 커야 유의미"
printf "  %-10s %10s %10s %12s\n" "effort" "tokens" "rlen" "finish"
for E in none low high max; do
 for rep in $(seq "$REPEAT"); do
  R=$(call 0.7 "$E")
  ERR=$(echo "$R" | jq -r '.error.message // empty')
  if [ -n "$ERR" ]; then
    printf "  %-10s %s\n" "$E" "ERROR: ${ERR:0:50}"
  else
    L=$(echo "$R" | jq -r "$RLEN")
    printf "  %-10s %10s %10s %12s\n" "$E" \
      "$(echo "$R" | jq -r '.usage.completion_tokens // "?"')" \
      "$L" \
      "$(echo "$R" | jq -r '.choices[0].finish_reason // "?"')"
  fi
 done
done
echo "  * finish가 length면 잘린 것. rlen은 하한값으로만 취급"

echo
echo "── 3. 온도 판정 (답 세기) ──"
echo "  같은 프롬프트를 반복해 답이 몇 종류 나오는지 센다"
echo "  저온에서 한 종류, 고온에서 여러 종류면 작동"
WORD='딱 한 글자만 출력해. 설명 금지. 다음 중 하나: 가 나 다 라 마'
N=6
# rpm이 낮으면 표본을 줄여 대기시간 폭주를 막는다
[ -n "$RPM" ] && [ "$RPM" -le 6 ] 2>/dev/null && { N=4; echo "  (rpm이 낮아 표본 ${N}회로 축소)"; }
for T in 0 1.5; do
  printf "  temp %-5s" "$T"
  for i in $(seq $N); do
    B=$(jq -n --arg m "$MODEL" --arg p "$WORD" --argjson t "$T" \
      '{model:$m,messages:[{role:"user",content:$p}],temperature:$t,max_tokens:8}')
    printf " %s" "$(request "$B" \
      | jq -r '.choices[0].message.content // ("!" + (.error.message // "빈응답")[0:12])' \
      | tr -d '\n ')"
  done
  printf "\n"
done

rm -f /tmp/.probe_hdr

echo
echo "── 4. 판정 가이드 ──"
cat <<'EOF'
  [effort]
    none에서 rlen=0                      → 추론 on/off 제어는 작동
    none 포함 전부 0                     → 비추론 모델이거나 라우트 OFF 고정
    1번에서 에러 없음                    → 파라미터가 필터링되는 중
    finish=length                        → 잘림. max_tokens를 올려 재측정

    ! low/high/max 간 서열은 편차가 커서 1회로는 판정 못 한다.
      같은 단계를 여러 번 재고(WS_REPEAT), 반복 간 폭보다
      단계 간 차이가 뚜렷할 때만 "단조 증가"로 본다.

  [온도]
    temp 0에서 전부 같은 답
      + 1.5에서 두 종류 이상            → 작동
    양쪽 다 골고루 섞임                  → 온도 무시, 라우트 고정값
    양쪽 다 한 종류                      → 온도가 0 근처로 고정
    ! 로 시작하는 칸                     → 호출 실패. 에러 앞부분이 찍힌다

    판정 기준은 "어떤 답이 나왔나"가 아니라 "갈렸나"다.
    고온에서 한 글자가 연속으로 나오는 것은 흔하다. 분포가
    평평해질 뿐 균등해지지는 않기 때문이다.

  [레이트리밋]
    rpm 미확인으로 뜨는데 429가 잦으면 WS_RPM=n 으로 직접 지정한다.
    0번 메타데이터 출력에서 실제 필드명을 확인하고, 스크립트 상단
    RPM 후보 목록에 그 이름을 추가해두면 다음부터 자동으로 잡힌다.
    (wellspring은 rate_limit_rpm 을 쓴다)

    3번이 전부 !빈응답 이면 십중팔구 rpm 미감지다. 먼저 0번에서
    rpm 필드를 확인하고 다시 돌린다.
EOF
