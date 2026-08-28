# 모델 카탈로그

모델별로 실측 확인된 파라미터 동작. 확인 절차는 `endpoint-probing.md`, 자동화는 `probe.sh`.

기재는 실측된 것만 한다. 미확인 항목은 비워두고 추측으로 채우지 않는다.

---

## api.wellspring.encrypt.gay

### glm-5.2

- 확인일: 2026.08.28
- 온도: **작동**
- 추론 문법: `reasoning_effort` (최상위 평문 키)
- 허용값: `none` `low` `high` `max`
- 추론 끄기: 가능 (`none`)
- 파라미터 필터링: 없음 (값 검증 후 에러 반환)

추론 조절 (RisuAI 추가 파라미터 칸. 값만 갈아끼우면 됨):

```
reasoning_effort=max
```

측정치 (temperature 0.7 고정):

| effort | completion_tokens | reasoning 길이 |
|---|---|---|
| none | 594 | 0 |
| low | 2512 | 3193 |
| high | 2490 | 3586 |
| max | 3103 | 4548 |

특이사항:
- `xhigh` 없음. OpenRouter 문서의 `high`/`xhigh` 체계와 다르다.
- `reasoning=json::{...}` 형식 거부.
- `reasoning_effort` 미지정 시 추론이 켜져 있는 것이 기본이다.

### deepseek-v4-flash-0731

- 확인일: 2026.08.28
- 온도: **작동** (답 세기 방식. 트레이스 방식은 이 모델에 안 통함)
- 추론 문법: `reasoning_effort` (최상위 평문 키)
- 허용값: `none` `low` `high` `max`
- 추론 끄기: 가능 (`none`). **미지정 시에도 OFF가 기본**
- 파라미터 필터링: 없음 (값 검증 후 에러 반환)
- rpm: 10

추론 조절 (RisuAI 추가 파라미터 칸. 값만 갈아끼우면 됨):

```
reasoning_effort=low
```

측정치 (temperature 0.7 고정, max_tokens 4000):

| effort | completion_tokens | reasoning 길이 |
|---|---|---|
| none | 919 | 0 |
| low | 3527 | 2424 |
| high | 6829 | 15579 |
| max | 8000 | 17008 |

측정치 (답 세기, `가 나 다 라 마` 중 한 글자):

| temperature | 결과 |
|---|---|
| 0 | 가 가 가 가 가 가 |
| 1.5 | 마 마 마 가 / 가 마 가 가 |

특이사항:
- **추론량이 극단적.** low→high에서 6.4배로 폭발한다. GLM은 같은 구간이 1.1배. high 이상은 지연시간 부담이 크므로 파이프라인 투입 시 `low`까지만 쓴다.
- max의 completion_tokens가 정확히 8000. 요청한 max_tokens(4000)를 넘겼으므로 추론 토큰이 상한에 안 잡히거나 라우트 상한 8000이 걸린 것으로 보인다. **max의 rlen 17008은 하한값**이며 실제로는 더 클 수 있다.
- GLM과 반대로 기본값이 추론 OFF다.
- **추론 트레이스 길이로는 온도 판정이 안 된다.** 같은 온도 안에서도 길이가 2.6배까지 벌어져(temperature 0에서 2597 vs 6679) 그룹이 겹친다.
- 답 세기를 몰아 쏘면 429가 난다. 7초 간격 필요.

---

## 신규 항목 템플릿

```markdown
### <모델 id>

- 확인일: YYYY.MM.DD
- 온도: 작동 / 무시 / 미확인
- 추론 문법: <키 이름과 계열>
- 허용값: <에러 메시지에서 캔 목록>
- 추론 끄기: 가능 / 불가
- 파라미터 필터링: 없음 / 있음
- rpm: <메타데이터에서 확인한 값>

추론 조절 (RisuAI 추가 파라미터 칸. 값만 갈아끼우면 됨):

<코드블럭 하나>

측정치 (temperature ? 고정):

| effort | completion_tokens | reasoning 길이 |
|---|---|---|

특이사항:
```
