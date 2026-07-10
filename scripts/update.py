#!/usr/bin/env python3
"""
LLM 파라미터 레퍼런스 자동 업데이트 스크립트.

백엔드는 OpenAI 호환 엔드포인트라면 무엇이든 사용 가능:
  LLM_BASE_URL  예: https://api.cerebras.ai/v1 | https://openrouter.ai/api/v1
  LLM_API_KEY   해당 백엔드 키
  LLM_MODEL     예: llama-3.3-70b | qwen-3-235b-a22b
  TAVILY_API_KEY  Tavily 검색 키

변경점이 있으면 data/models.json을 덮어쓰고 exit code 0 + changes.md 생성.
변경 없으면 changes.md를 만들지 않음 (워크플로가 PR 생성을 스킵).
"""
import json
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_PATH = os.path.join(ROOT, "data", "models.json")
CHANGES_PATH = os.path.join(ROOT, "changes.md")

LLM_BASE_URL = os.environ["LLM_BASE_URL"].rstrip("/")
LLM_API_KEY = os.environ["LLM_API_KEY"]
LLM_MODEL = os.environ["LLM_MODEL"]
TAVILY_API_KEY = os.environ["TAVILY_API_KEY"]

# Cerebras류 TPM 사전계산 이슈 방지: 항상 max_tokens 명시
MAX_TOKENS = int(os.environ.get("LLM_MAX_TOKENS", "2000"))


def http_json(url: str, payload: dict, headers: dict) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "User-Agent": "llm-param-ref/1.0 (+github-actions)",
            **headers,
        },
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def tavily_search(query: str) -> list[dict]:
    res = http_json(
        "https://api.tavily.com/search",
        {
            "query": query,
            "search_depth": "basic",
            "max_results": 4,
            "include_answer": False,
        },
        {"Authorization": f"Bearer {TAVILY_API_KEY}"},
    )
    return [
        {"url": r["url"], "title": r.get("title", ""), "content": r.get("content", "")[:1200]}
        for r in res.get("results", [])
    ]


def llm_chat(system: str, user: str) -> str:
    res = http_json(
        f"{LLM_BASE_URL}/chat/completions",
        {
            "model": LLM_MODEL,
            "max_tokens": MAX_TOKENS,
            "temperature": 0.0,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        },
        {"Authorization": f"Bearer {LLM_API_KEY}"},
    )
    return res["choices"][0]["message"]["content"]


SYSTEM_PROMPT = """You maintain a JSON reference of LLM API parameters (reasoning/thinking control, temperature).
You will receive one model's current JSON entry and fresh web search snippets.

Rules:
- Output ONLY a JSON object, no markdown fences, no prose.
- Output {"changed": false} if the search snippets do not clearly contradict or extend the entry.
- If there IS a verifiable change, output {"changed": true, "entry": <full updated entry>, "reason": "<one line>", "source_urls": [...]}.
- NEVER invent parameter names. Only use parameter names that literally appear in the snippets.
- If unsure, set "verified": false on the entry rather than guessing.
- Keep all existing fields; only modify what the sources support.
"""


def strip_fences(text: str) -> str:
    t = text.strip()
    if t.startswith("```"):
        t = t.split("\n", 1)[1] if "\n" in t else t
        if t.rstrip().endswith("```"):
            t = t.rstrip()[:-3]
    return t.strip()


def validate_entry(entry: dict, original: dict) -> bool:
    """스키마 최소 검증: id 불변, 필수 키 존재."""
    required = {"id", "name", "provider", "track", "reasoning", "temperature"}
    return (
        isinstance(entry, dict)
        and required.issubset(entry.keys())
        and entry["id"] == original["id"]
    )


def main() -> None:
    with open(DATA_PATH, encoding="utf-8") as f:
        data = json.load(f)

    changelog: list[str] = []

    for i, model in enumerate(data["models"]):
        if not model.get("track", False):
            continue

        query = f'{model["name"]} API parameters reasoning thinking temperature documentation'
        print(f"[search] {model['id']}: {query}")
        try:
            snippets = tavily_search(query)
        except Exception as e:
            print(f"  ! tavily failed: {e}", file=sys.stderr)
            continue
        if not snippets:
            continue

        user_msg = json.dumps(
            {"current_entry": model, "search_results": snippets},
            ensure_ascii=False,
        )
        try:
            raw = llm_chat(SYSTEM_PROMPT, user_msg)
            result = json.loads(strip_fences(raw))
        except Exception as e:
            print(f"  ! llm/parse failed: {e}", file=sys.stderr)
            continue

        if result.get("changed") and validate_entry(result.get("entry", {}), model):
            data["models"][i] = result["entry"]
            urls = ", ".join(result.get("source_urls", []))
            changelog.append(f"- **{model['name']}**: {result.get('reason', '')} ({urls})")
            print(f"  → changed: {result.get('reason', '')}")
        else:
            print("  → no change")

    if changelog:
        from datetime import date

        data["meta"]["last_updated"] = date.today().isoformat()
        with open(DATA_PATH, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        with open(CHANGES_PATH, "w", encoding="utf-8") as f:
            f.write("## 자동 감지된 변경점\n\n" + "\n".join(changelog) + "\n")
        print(f"\n{len(changelog)} change(s) written.")
    else:
        print("\nNo changes detected.")


if __name__ == "__main__":
    main()
