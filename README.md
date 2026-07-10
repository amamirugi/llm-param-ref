# LLM Parameter Reference — 자동 업데이트 파이프라인

정적 사이트(`index.html` + `data/models.json`)와 GitHub Actions 수집 파이프라인으로 구성돼요.

## 구조

```
├── index.html                  # 사이트 (data/models.json을 fetch해서 렌더)
├── data/models.json            # 단일 데이터 소스 — 여기만 고치면 사이트에 반영
├── scripts/update.py           # Tavily 검색 → LLM 정리 → 변경점 감지
└── .github/workflows/update.yml # 수동 버튼 + 매주 자동 실행 → PR 생성
```

## 초기 설정 (1회)

GitHub 리포 → Settings → Secrets and variables → Actions:

| 종류 | 이름 | 예시 |
|---|---|---|
| Secret | `LLM_API_KEY` | Cerebras/OpenRouter 등 키 |
| Secret | `LLM_BASE_URL` | `https://api.cerebras.ai/v1` |
| Secret | `TAVILY_API_KEY` | Tavily 키 (무료 월 1,000크레딧) |
| Variable | `LLM_MODEL` | `llama-3.3-70b` |

백엔드는 OpenAI 호환(`/chat/completions`)이면 뭐든 가능해요. `max_tokens`는
항상 명시되므로(기본 2000) Cerebras TPM 사전계산 429 문제는 발생하지 않아요.

## 실행 방법

- **버튼 딸깍**: Actions 탭 → "Update LLM Reference" → Run workflow.
  이때 뜨는 입력란에 엔드포인트/모델을 즉석에서 넣으면 그 회차만 그 백엔드로 실행돼요.
  비워두면 위 Secret/Variable 기본값 사용.
- **자동**: 매주 월요일 KST 오전 9시.

변경이 감지되면 PR이 생성되고, Vercel이 PR 프리뷰를 배포해요.
프리뷰 확인 후 머지하면 본 사이트가 갱신돼요. 변경이 없으면 아무 일도 안 일어나요.

## Vercel 배포

Vercel 대시보드에서 이 리포를 Import → Framework Preset: **Other**, 빌드 설정 없음.
정적 파일이라 그대로 서빙돼요. (로컬에서 `file://`로 열면 fetch가 막히니
`python -m http.server`로 확인하세요.)

## 환각 방지 장치

- 프롬프트에 "스니펫에 문자 그대로 등장하는 파라미터명만 사용" 규칙 명시
- 스키마 검증 통과 실패 시 변경 무시
- 직접 커밋 없이 PR 경유 → 사람이 최종 승인
- 불확실하면 `verified: false`로 표시 (사이트에 UNVERIFIED 스탬프로 노출)
