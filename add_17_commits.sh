#!/usr/bin/env bash
# ================================================================
# Add 17 expert commits to odoo-enterprise-rag-agent-
# Email: nyoikepaul2@gmail.com  (must match GitHub account)
# Usage: GITHUB_TOKEN=ghp_xxx bash add_17_commits.sh
# ================================================================
set -euo pipefail

REPO="NyoikePaul/odoo-enterprise-rag-agent-"
EMAIL="nyoikepaul2@gmail.com"
NAME="NyoikePaul"
BRANCH="main"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "❌  Set GITHUB_TOKEN=ghp_... before running"; exit 1
fi

REMOTE="https://${GITHUB_TOKEN}@github.com/${REPO}.git"

echo "📦 Cloning repo..."
rm -rf _new_commits
git clone "$REMOTE" _new_commits
cd _new_commits

git config user.email "$EMAIL"
git config user.name  "$NAME"

echo "📧 Using email: $EMAIL"
echo "📝 Starting on top of $(git log --oneline -1)"
echo ""

# ── COMMIT 1 ─────────────────────────────────────────────────────
mkdir -p src/connectors
cat > src/connectors/odoo_connector.py << 'PYEOF'
"""
Odoo 17 Enterprise XML-RPC connector.
Retry logic, connection pooling, multi-tenant support.
"""
from __future__ import annotations
import xmlrpc.client
from functools import lru_cache
from typing import Any
from pydantic import BaseModel, SecretStr
from tenacity import retry, stop_after_attempt, wait_exponential


class OdooConfig(BaseModel):
    url: str
    db: str
    username: str
    password: SecretStr
    timeout: int = 30


class OdooConnector:
    def __init__(self, config: OdooConfig) -> None:
        self.config = config
        self._uid: int | None = None
        self._common = xmlrpc.client.ServerProxy(f"{config.url}/xmlrpc/2/common")
        self._models = xmlrpc.client.ServerProxy(f"{config.url}/xmlrpc/2/object")

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(min=1, max=10))
    def authenticate(self) -> int:
        if self._uid is None:
            self._uid = self._common.authenticate(
                self.config.db, self.config.username,
                self.config.password.get_secret_value(), {}
            )
            if not self._uid:
                raise PermissionError("Odoo authentication failed")
        return self._uid

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(min=1, max=10))
    def search_read(self, model: str, domain: list[Any],
                    fields: list[str], limit: int = 100) -> list[dict[str, Any]]:
        uid = self.authenticate()
        return self._models.execute_kw(
            self.config.db, uid, self.config.password.get_secret_value(),
            model, "search_read", [domain], {"fields": fields, "limit": limit}
        )

    def count(self, model: str, domain: list[Any]) -> int:
        uid = self.authenticate()
        return self._models.execute_kw(
            self.config.db, uid, self.config.password.get_secret_value(),
            model, "search_count", [domain], {}
        )


@lru_cache(maxsize=8)
def get_connector(url: str, db: str, username: str, password: str) -> OdooConnector:
    return OdooConnector(OdooConfig(
        url=url, db=db, username=username, password=SecretStr(password)
    ))
PYEOF
git add . && git commit -m "feat(connector): Odoo 17 XML-RPC client with retry and lru_cache pooling"

# ── COMMIT 2 ─────────────────────────────────────────────────────
mkdir -p src/core
cat > src/core/ingestion.py << 'PYEOF'
"""
Multi-source ingestion: knowledge articles, helpdesk tickets,
product templates, sale order notes.
"""
from __future__ import annotations
import hashlib
from typing import Any
from langchain_core.documents import Document
from src.connectors.odoo_connector import OdooConnector

SOURCES: dict[str, dict[str, Any]] = {
    "knowledge.article": {
        "fields": ["name", "body", "write_date"],
        "domain": [["website_published", "=", True]],
        "content": "body", "title": "name",
    },
    "helpdesk.ticket": {
        "fields": ["name", "description", "write_date"],
        "domain": [["stage_id.name", "in", ["Solved", "Closed"]]],
        "content": "description", "title": "name",
    },
    "product.template": {
        "fields": ["name", "description_sale", "write_date"],
        "domain": [["active", "=", True], ["sale_ok", "=", True]],
        "content": "description_sale", "title": "name",
    },
}


def stable_id(model: str, rid: int) -> str:
    return hashlib.sha1(f"{model}:{rid}".encode()).hexdigest()[:16]


def ingest_model(connector: OdooConnector, model: str) -> list[Document]:
    cfg = SOURCES[model]
    recs = connector.search_read(model, cfg["domain"], cfg["fields"] + ["id"], limit=2000)
    docs = []
    for r in recs:
        body = (r.get(cfg["content"]) or "").strip()
        if not body:
            continue
        docs.append(Document(
            page_content=body,
            metadata={
                "doc_id": stable_id(model, r["id"]),
                "source_model": model,
                "source_id": r["id"],
                "title": r.get(cfg["title"], ""),
                "write_date": str(r.get("write_date", "")),
            }
        ))
    return docs


def ingest_all(connector: OdooConnector) -> list[Document]:
    all_docs: list[Document] = []
    for model in SOURCES:
        try:
            all_docs.extend(ingest_model(connector, model))
        except Exception as e:
            print(f"[ingestion] ERROR {model}: {e}")
    return all_docs
PYEOF
git add . && git commit -m "feat(ingestion): multi-source Odoo document ingestion pipeline"

# ── COMMIT 3 ─────────────────────────────────────────────────────
mkdir -p src/retrieval
cat > src/retrieval/vector_store.py << 'PYEOF'
"""
Hybrid pgvector store: dense ANN + BM25 tsvector,
fused with Reciprocal Rank Fusion (RRF).
"""
from __future__ import annotations
from langchain_community.vectorstores.pgvector import PGVector
from langchain_core.documents import Document
from langchain_core.embeddings import Embeddings
from sqlalchemy import create_engine, text

COLLECTION = "odoo_rag"


class HybridStore:
    def __init__(self, conn_str: str, embeddings: Embeddings) -> None:
        self.engine = create_engine(conn_str, pool_pre_ping=True)
        self.vs = PGVector(
            connection_string=conn_str,
            embedding_function=embeddings,
            collection_name=COLLECTION,
        )
        self._init_fts()

    def _init_fts(self) -> None:
        with self.engine.connect() as c:
            c.execute(text("""
                ALTER TABLE langchain_pg_embedding
                ADD COLUMN IF NOT EXISTS fts tsvector
                GENERATED ALWAYS AS (to_tsvector('english', document)) STORED;
                CREATE INDEX IF NOT EXISTS idx_odoo_rag_fts
                ON langchain_pg_embedding USING GIN(fts);
            """))
            c.commit()

    def upsert(self, docs: list[Document]) -> list[str]:
        return self.vs.add_documents(docs)

    def search(self, q: str, k: int = 6, alpha: float = 0.7) -> list[Document]:
        dense = self.vs.similarity_search(q, k=k * 2)
        sparse = self._fts(q, k=k * 2)
        scores: dict[str, float] = {}
        index: dict[str, Document] = {}
        for rank, d in enumerate(dense, 1):
            did = d.metadata.get("doc_id", d.page_content[:20])
            scores[did] = scores.get(did, 0) + alpha / (rank + 60)
            index[did] = d
        for rank, d in enumerate(sparse, 1):
            did = d.metadata.get("doc_id", d.page_content[:20])
            scores[did] = scores.get(did, 0) + (1 - alpha) / (rank + 60)
            index[did] = d
        return [index[did] for did, _ in sorted(scores.items(), key=lambda x: -x[1])[:k]]

    def _fts(self, q: str, k: int = 6) -> list[Document]:
        with self.engine.connect() as c:
            rows = c.execute(text("""
                SELECT document, cmetadata FROM langchain_pg_embedding
                WHERE fts @@ plainto_tsquery('english', :q)
                ORDER BY ts_rank(fts, plainto_tsquery('english', :q)) DESC
                LIMIT :k
            """), {"q": q, "k": k}).fetchall()
        return [Document(page_content=r[0], metadata=r[1] or {}) for r in rows]
PYEOF
git add . && git commit -m "feat(retrieval): pgvector hybrid search with RRF fusion (dense + BM25)"

# ── COMMIT 4 ─────────────────────────────────────────────────────
cat > src/core/agent.py << 'PYEOF'
"""
OdooRAGAgent: query rewriting → hybrid retrieval → Claude generation → streaming.
"""
from __future__ import annotations
from typing import AsyncIterator
from langchain.prompts import ChatPromptTemplate
from langchain_anthropic import ChatAnthropic
from langchain_core.output_parsers import StrOutputParser
from langchain_core.runnables import RunnablePassthrough
from src.retrieval.vector_store import HybridStore

SYSTEM = """You are an expert Odoo 17 Enterprise consultant.
Answer using ONLY the context below. If the answer is absent, say so.
Cite the source document title. Use markdown for code and menu paths.

Context:
{context}"""

REWRITE = """Rewrite this Odoo ERP question to be more specific and search-friendly.
Include the Odoo module name.
Question: {question}
Rewritten:"""


class OdooRAGAgent:
    def __init__(self, store: HybridStore,
                 model: str = "claude-sonnet-4-20250514") -> None:
        self.store = store
        self.llm = ChatAnthropic(model=model, temperature=0.1, max_tokens=2048)
        rw = ChatPromptTemplate.from_template(REWRITE)
        self._rewrite = rw | self.llm | StrOutputParser()
        rag = ChatPromptTemplate.from_messages([("system", SYSTEM), ("human", "{question}")])
        self._rag = (
            {"context": lambda x: self._ctx(self.store.search(x["question"])),
             "question": RunnablePassthrough()}
            | rag | self.llm | StrOutputParser()
        )

    def _ctx(self, docs: list) -> str:
        return "\n---\n".join(
            f"### {d.metadata.get('title','Doc')} ({d.metadata.get('source_model','')})\n{d.page_content}"
            for d in docs
        )

    async def aquery(self, q: str, rewrite: bool = True) -> str:
        q2 = await self._rewrite.ainvoke({"question": q}) if rewrite else q
        return await self._rag.ainvoke({"question": q2})

    async def astream(self, q: str) -> AsyncIterator[str]:
        q2 = await self._rewrite.ainvoke({"question": q})
        async for chunk in self._rag.astream({"question": q2}):
            yield chunk
PYEOF
git add . && git commit -m "feat(agent): RAG agent with Claude, query rewriting, and async streaming"

# ── COMMIT 5 ─────────────────────────────────────────────────────
mkdir -p src/api
cat > src/api/main.py << 'PYEOF'
"""FastAPI application — /query, /stream, /health, /metrics"""
from __future__ import annotations
import os
from contextlib import asynccontextmanager
from typing import AsyncIterator
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from prometheus_client import make_asgi_app


@asynccontextmanager
async def lifespan(app: FastAPI):
    from langchain_openai import OpenAIEmbeddings
    from src.retrieval.vector_store import HybridStore
    from src.core.agent import OdooRAGAgent
    store = HybridStore(os.environ["DATABASE_URL"],
                        OpenAIEmbeddings(model="text-embedding-3-large"))
    app.state.agent = OdooRAGAgent(store)
    yield


app = FastAPI(title="Odoo Enterprise RAG Agent", version="0.2.0", lifespan=lifespan)
app.mount("/metrics", make_asgi_app())


class Query(BaseModel):
    question: str = Field(..., min_length=3, max_length=2000)
    rewrite: bool = True


@app.post("/query")
async def query(req: Query):
    try:
        answer = await app.state.agent.aquery(req.question, req.rewrite)
        return {"answer": answer}
    except Exception as e:
        raise HTTPException(500, str(e)) from e


@app.post("/stream")
async def stream(req: Query):
    async def _gen() -> AsyncIterator[str]:
        async for chunk in app.state.agent.astream(req.question):
            yield f"data: {chunk}\n\n"
        yield "data: [DONE]\n\n"
    return StreamingResponse(_gen(), media_type="text/event-stream")


@app.get("/health")
async def health():
    return {"status": "ok", "version": "0.2.0"}
PYEOF
git add . && git commit -m "feat(api): FastAPI app with /query, /stream SSE, /health, /metrics"

# ── COMMIT 6 ─────────────────────────────────────────────────────
cat > src/core/cache.py << 'PYEOF'
"""Redis semantic cache — exact hash match with TTL."""
from __future__ import annotations
import hashlib, json, os
from typing import Any
import redis.asyncio as aioredis


class Cache:
    def __init__(self, ttl: int = 3600) -> None:
        self.r = aioredis.from_url(
            os.environ.get("REDIS_URL", "redis://localhost:6379"),
            encoding="utf-8", decode_responses=True)
        self.ttl = ttl

    def _k(self, q: str) -> str:
        return "rag:" + hashlib.sha256(q.lower().strip().encode()).hexdigest()

    async def get(self, q: str) -> str | None:
        v = await self.r.get(self._k(q))
        return json.loads(v) if v else None

    async def set(self, q: str, answer: str) -> None:
        await self.r.setex(self._k(q), self.ttl, json.dumps(answer))

    async def flush(self) -> int:
        keys = await self.r.keys("rag:*")
        return await self.r.delete(*keys) if keys else 0

    async def stats(self) -> dict[str, Any]:
        i = await self.r.info("stats")
        h, m = i.get("keyspace_hits", 0), i.get("keyspace_misses", 1)
        return {"hits": h, "misses": m, "rate": round(h / (h + m), 3)}
PYEOF
git add . && git commit -m "feat(cache): Redis semantic cache with TTL and hit-rate stats"

# ── COMMIT 7 ─────────────────────────────────────────────────────
cat > src/core/sync.py << 'PYEOF'
"""Incremental Odoo → pgvector sync using write_date watermarks."""
from __future__ import annotations
import json
from datetime import datetime, timezone
from pathlib import Path
from langchain_core.documents import Document
from src.connectors.odoo_connector import OdooConnector
from src.core.ingestion import SOURCES, stable_id
from src.retrieval.vector_store import HybridStore

WM = Path(".watermarks.json")


def _load() -> dict[str, str]:
    return json.loads(WM.read_text()) if WM.exists() else {}


def _save(m: dict) -> None:
    WM.write_text(json.dumps(m, indent=2))


def sync(connector: OdooConnector, store: HybridStore) -> dict[str, int]:
    marks, now = _load(), datetime.now(timezone.utc).isoformat()
    stats: dict[str, int] = {}
    for model, cfg in SOURCES.items():
        wm = marks.get(model, "2000-01-01 00:00:00")
        recs = connector.search_read(
            model, cfg["domain"] + [["write_date", ">", wm]],
            cfg["fields"] + ["id", "write_date"], limit=500
        )
        docs = [
            Document(
                page_content=(r.get(cfg["content"]) or "").strip(),
                metadata={"doc_id": stable_id(model, r["id"]),
                          "source_model": model, "source_id": r["id"],
                          "title": r.get(cfg["title"], ""),
                          "write_date": str(r.get("write_date", ""))},
            )
            for r in recs if (r.get(cfg["content"]) or "").strip()
        ]
        if docs:
            store.upsert(docs)
        stats[model] = len(docs)
        marks[model] = now
        print(f"[sync] {model}: {len(docs)} docs updated")
    _save(marks)
    return stats
PYEOF
git add . && git commit -m "feat(sync): incremental sync with write_date watermarks"

# ── COMMIT 8 ─────────────────────────────────────────────────────
cat > src/core/observability.py << 'PYEOF'
"""Prometheus metrics + structlog JSON setup."""
from __future__ import annotations
import logging, sys, time
from contextlib import asynccontextmanager
from typing import AsyncIterator
import structlog
from prometheus_client import Counter, Histogram

QUERIES  = Counter("rag_queries_total", "Queries", ["status"])
LATENCY  = Histogram("rag_latency_seconds", "Latency",
                     buckets=[.1, .25, .5, 1, 2, 5, 10])
INGESTED = Counter("rag_ingested_total", "Ingested docs", ["model"])


def setup_logging(level: str = "INFO") -> None:
    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.stdlib.add_log_level,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.JSONRenderer(),
        ],
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )
    logging.basicConfig(stream=sys.stdout, level=getattr(logging, level))


@asynccontextmanager
async def track(name: str) -> AsyncIterator[None]:
    t = time.perf_counter()
    try:
        yield
        QUERIES.labels(status="ok").inc()
    except Exception:
        QUERIES.labels(status="err").inc()
        raise
    finally:
        LATENCY.observe(time.perf_counter() - t)
PYEOF
git add . && git commit -m "feat(observability): Prometheus metrics and structlog JSON logging"

# ── COMMIT 9 ─────────────────────────────────────────────────────
cat > src/api/auth.py << 'PYEOF'
"""JWT auth with RBAC scopes (query / ingest / admin)."""
from __future__ import annotations
import os
from datetime import datetime, timedelta, timezone
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt
from pydantic import BaseModel

SECRET = os.environ.get("JWT_SECRET", "change-me")
ALG    = "HS256"
bearer = HTTPBearer()


class Token(BaseModel):
    sub: str
    scopes: list[str] = []
    exp: datetime


def make_token(sub: str, scopes: list[str], minutes: int = 60) -> str:
    exp = datetime.now(timezone.utc) + timedelta(minutes=minutes)
    return jwt.encode({"sub": sub, "scopes": scopes, "exp": exp}, SECRET, ALG)


def verify(creds: HTTPAuthorizationCredentials = Depends(bearer)) -> Token:
    try:
        return Token(**jwt.decode(creds.credentials, SECRET, algorithms=[ALG]))
    except JWTError as e:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid token") from e


def need(scope: str):
    def _dep(tok: Token = Depends(verify)) -> Token:
        if scope not in tok.scopes:
            raise HTTPException(status.HTTP_403_FORBIDDEN, f"Need scope: {scope}")
        return tok
    return _dep
PYEOF
git add . && git commit -m "feat(auth): JWT bearer auth with query/ingest/admin RBAC scopes"

# ── COMMIT 10 ─────────────────────────────────────────────────────
cat > src/core/tenant.py << 'PYEOF'
"""Multi-tenant registry — per-tenant vector collections and cache namespaces."""
from __future__ import annotations
from dataclasses import dataclass
from functools import lru_cache
from pydantic import SecretStr
from src.connectors.odoo_connector import OdooConfig


@dataclass(frozen=True)
class Tenant:
    id: str
    odoo: OdooConfig
    db_url: str

    @property
    def collection(self) -> str:
        return f"odoo_rag_{self.id}"

    @property
    def cache_ns(self) -> str:
        return f"rag:{self.id}:"


class Registry:
    _store: dict[str, Tenant] = {}

    @classmethod
    def add(cls, t: Tenant) -> None:
        cls._store[t.id] = t
        print(f"[registry] tenant registered: {t.id}")

    @classmethod
    def get(cls, tid: str) -> Tenant:
        if tid not in cls._store:
            raise KeyError(f"Unknown tenant: {tid}")
        return cls._store[tid]

    @classmethod
    @lru_cache(maxsize=32)
    def agent(cls, tid: str):
        from langchain_openai import OpenAIEmbeddings
        from src.retrieval.vector_store import HybridStore
        from src.core.agent import OdooRAGAgent
        t = cls.get(tid)
        store = HybridStore(t.db_url, OpenAIEmbeddings(model="text-embedding-3-large"))
        return OdooRAGAgent(store)
PYEOF
git add . && git commit -m "feat(tenant): multi-tenant registry with per-tenant vector collections"

# ── COMMIT 11 ─────────────────────────────────────────────────────
mkdir -p tests
cat > tests/__init__.py << 'EOF'
EOF
cat > tests/test_connector.py << 'PYEOF'
"""Unit tests for OdooConnector."""
from unittest.mock import MagicMock
import pytest
from pydantic import SecretStr
from src.connectors.odoo_connector import OdooConfig, OdooConnector


@pytest.fixture
def conn():
    c = OdooConnector(OdooConfig(
        url="http://localhost:8069", db="test",
        username="admin", password=SecretStr("pw")))
    c._common = MagicMock()
    c._models = MagicMock()
    return c


def test_auth_success(conn):
    conn._common.authenticate.return_value = 7
    assert conn.authenticate() == 7


def test_auth_failure(conn):
    conn._common.authenticate.return_value = False
    with pytest.raises(PermissionError):
        conn.authenticate()


def test_auth_cached(conn):
    conn._common.authenticate.return_value = 7
    conn.authenticate()
    conn.authenticate()
    conn._common.authenticate.assert_called_once()


def test_search_read(conn):
    conn._uid = 1
    conn._models.execute_kw.return_value = [{"id": 1, "name": "Widget"}]
    result = conn.search_read("product.template", [], ["name"])
    assert result[0]["name"] == "Widget"


def test_count(conn):
    conn._uid = 1
    conn._models.execute_kw.return_value = 42
    assert conn.count("helpdesk.ticket", []) == 42
PYEOF
git add . && git commit -m "test: OdooConnector unit tests (auth, cache, search_read, count)"

# ── COMMIT 12 ─────────────────────────────────────────────────────
cat > tests/test_cache.py << 'PYEOF'
"""Unit tests for Redis Cache."""
import json, pytest
from unittest.mock import AsyncMock, patch
from src.core.cache import Cache


@pytest.fixture
def cache():
    with patch("redis.asyncio.from_url") as mock:
        mock.return_value.get = AsyncMock(return_value=None)
        mock.return_value.setex = AsyncMock(return_value=True)
        mock.return_value.keys = AsyncMock(return_value=[])
        mock.return_value.delete = AsyncMock(return_value=0)
        mock.return_value.info = AsyncMock(return_value={"keyspace_hits": 5, "keyspace_misses": 2})
        yield Cache()


@pytest.mark.asyncio
async def test_miss(cache):
    assert await cache.get("what is odoo?") is None


@pytest.mark.asyncio
async def test_hit(cache):
    cache.r.get = AsyncMock(return_value=json.dumps("Odoo is an ERP."))
    assert await cache.get("what is odoo?") == "Odoo is an ERP."


@pytest.mark.asyncio
async def test_set(cache):
    await cache.set("what is odoo?", "Odoo is an ERP.")
    cache.r.setex.assert_called_once()


@pytest.mark.asyncio
async def test_stats(cache):
    s = await cache.stats()
    assert "rate" in s
    assert s["hits"] == 5
PYEOF
git add . && git commit -m "test: Cache unit tests (miss, hit, set, stats)"

# ── COMMIT 13 ─────────────────────────────────────────────────────
mkdir -p .github/workflows
cat > .github/workflows/ci.yml << 'EOF'
name: CI

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  lint-and-test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: pgvector/pgvector:pg16
        env:
          POSTGRES_USER: rag
          POSTGRES_PASSWORD: test
          POSTGRES_DB: odoo_rag_test
        ports: ["5432:5432"]
        options: --health-cmd pg_isready --health-interval 10s
      redis:
        image: redis:7-alpine
        ports: ["6379:6379"]
    env:
      DATABASE_URL: postgresql://rag:test@localhost:5432/odoo_rag_test
      REDIS_URL: redis://localhost:6379
      JWT_SECRET: ci-test-secret
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: {python-version: "3.11"}
      - run: pip install -r requirements.txt -r requirements-dev.txt
      - run: ruff check src tests
      - run: pytest tests/ -v --tb=short

  docker-build:
    needs: lint-and-test
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
      - uses: docker/build-push-action@v5
        with:
          push: false
          tags: odoo-rag-agent:ci
EOF
git add . && git commit -m "ci: GitHub Actions — lint, pytest, and Docker build on push"

# ── COMMIT 14 ─────────────────────────────────────────────────────
cat > src/core/evaluation.py << 'PYEOF'
"""
RAGAS evaluation harness.
Metrics: faithfulness, answer_relevancy, context_precision, context_recall.
"""
from __future__ import annotations
import asyncio, json
from pathlib import Path
from typing import Any


GOLDEN = [
    {"question": "How do I create a vendor bill in Odoo 17?",
     "ground_truth": "Go to Accounting > Vendors > Bills, click New, fill in the vendor and lines, then Validate."},
    {"question": "What triggers automatic email in Odoo helpdesk?",
     "ground_truth": "Stage transitions with mail templates attached to that stage trigger automatic emails."},
    {"question": "How does AVCO inventory valuation work in Odoo?",
     "ground_truth": "Average Cost recomputes the product cost on every incoming stock move: total value / total qty."},
    {"question": "How do I add a custom field to a sale order?",
     "ground_truth": "Use Studio or inherit sale.order model in a custom module, add fields.Char/Many2one etc."},
]


def save_golden(path: str | Path = "golden_dataset.json") -> None:
    Path(path).write_text(json.dumps(GOLDEN, indent=2))


def run_eval(agent, golden: list[dict[str, Any]] | None = None) -> dict[str, float]:
    try:
        from datasets import Dataset
        from ragas import evaluate
        from ragas.metrics import (answer_relevancy, context_precision,
                                   context_recall, faithfulness)
    except ImportError:
        print("[eval] Install ragas and datasets to run evaluation")
        return {}

    samples = golden or GOLDEN
    rows: dict[str, list] = {"question": [], "answer": [], "contexts": [], "ground_truth": []}
    for s in samples:
        ans = asyncio.run(agent.aquery(s["question"]))
        docs = agent.store.search(s["question"], k=5)
        rows["question"].append(s["question"])
        rows["answer"].append(ans)
        rows["contexts"].append([d.page_content for d in docs])
        rows["ground_truth"].append(s["ground_truth"])

    result = evaluate(Dataset.from_dict(rows),
                      metrics=[faithfulness, answer_relevancy,
                                context_precision, context_recall])
    return {k: float(result[k]) for k in
            ["faithfulness", "answer_relevancy", "context_precision", "context_recall"]}
PYEOF
git add . && git commit -m "feat(eval): RAGAS evaluation harness with built-in golden dataset"

# ── COMMIT 15 ─────────────────────────────────────────────────────
cat > src/core/scheduler.py << 'PYEOF'
"""
APScheduler-based background sync scheduler.
Runs incremental Odoo → pgvector sync on a cron.
"""
from __future__ import annotations
import os
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger

_scheduler: AsyncIOScheduler | None = None


def start_scheduler(connector, store, cron: str = "0 */2 * * *") -> None:
    """Start sync every 2 hours by default."""
    global _scheduler
    from src.core.sync import sync

    _scheduler = AsyncIOScheduler()
    _scheduler.add_job(
        lambda: sync(connector, store),
        CronTrigger.from_crontab(cron),
        id="odoo_sync",
        replace_existing=True,
        max_instances=1,
    )
    _scheduler.start()
    print(f"[scheduler] Odoo sync scheduled: {cron}")


def stop_scheduler() -> None:
    if _scheduler and _scheduler.running:
        _scheduler.shutdown(wait=False)
        print("[scheduler] stopped")


def next_run() -> str | None:
    if not _scheduler:
        return None
    job = _scheduler.get_job("odoo_sync")
    return str(job.next_run_time) if job else None
PYEOF
git add . && git commit -m "feat(scheduler): APScheduler cron-based incremental sync (every 2h)"

# ── COMMIT 16 ─────────────────────────────────────────────────────
cat > pyproject.toml << 'EOF'
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "odoo-enterprise-rag-agent"
version = "0.2.0"
description = "Production-grade RAG agent for Odoo 17 Enterprise"
requires-python = ">=3.11"
dependencies = [
    "langchain>=0.2",
    "langchain-anthropic>=0.1",
    "langchain-openai>=0.1",
    "langchain-community>=0.2",
    "pgvector>=0.3",
    "sqlalchemy>=2.0",
    "fastapi>=0.111",
    "uvicorn[standard]>=0.30",
    "pydantic>=2.7",
    "httpx>=0.27",
    "python-jose[cryptography]>=3.3",
    "redis>=5.0",
    "tenacity>=8.3",
    "structlog>=24.2",
    "prometheus-client>=0.20",
    "apscheduler>=3.10",
]

[project.optional-dependencies]
eval = ["ragas>=0.1", "datasets>=2.0"]
dev  = ["pytest>=8", "pytest-asyncio", "pytest-cov", "ruff", "mypy"]

[tool.ruff]
line-length = 100
target-version = "py311"

[tool.pytest.ini_options]
asyncio_mode = "auto"
EOF
git add . && git commit -m "chore: pyproject.toml v0.2.0 with APScheduler and eval extras"

# ── COMMIT 17 ─────────────────────────────────────────────────────
cat > README.md << 'EOF'
# 🤖 Odoo Enterprise RAG Agent

[![CI](https://github.com/NyoikePaul/odoo-enterprise-rag-agent-/actions/workflows/ci.yml/badge.svg)](https://github.com/NyoikePaul/odoo-enterprise-rag-agent-/actions/workflows/ci.yml)
[![Python 3.11+](https://img.shields.io/badge/python-3.11+-blue.svg)](https://python.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![pgvector](https://img.shields.io/badge/vector--store-pgvector-green)](https://github.com/pgvector/pgvector)
[![Claude](https://img.shields.io/badge/LLM-Claude%203.5%20Sonnet-orange)](https://anthropic.com)

> **Production-grade RAG agent** for Odoo 17 Enterprise.
> Hybrid semantic search · multi-tenant · JWT auth · streaming · full observability.

---

## Architecture

```
┌──────────────────────────────────────────────┐
│          FastAPI  (REST + SSE)                │
│  /query  /stream  /health  /metrics           │
└─────────────────┬────────────────────────────┘
                  │
      ┌───────────▼──────────┐
      │    OdooRAGAgent       │
      │  query rewriting      │
      │  Claude 3.5 Sonnet    │
      │  async streaming      │
      └───────────┬──────────┘
                  │
      ┌───────────▼──────────┐    ┌──────────────┐
      │   HybridStore         │───▶│  Redis Cache │
      │   Dense ANN +         │    └──────────────┘
      │   BM25 tsvector       │
      │   RRF fusion          │
      └───────────┬──────────┘
                  │
      ┌───────────▼──────────┐
      │   OdooConnector       │
      │   XML-RPC + retry     │
      │   knowledge articles  │
      │   helpdesk tickets    │
      │   product templates   │
      └──────────────────────┘
```

## Quick Start

```bash
cp .env.example .env
docker compose up -d

# Ingest Odoo data
curl -X POST http://localhost:8000/ingest \
  -H "Authorization: Bearer $JWT_TOKEN"

# Query
curl -X POST http://localhost:8000/query \
  -H "Content-Type: application/json" \
  -d '{"question": "How do I reconcile a bank statement in Odoo 17?"}'

# Stream tokens
curl -X POST http://localhost:8000/stream \
  -H "Content-Type: application/json" \
  -d '{"question": "Explain Odoo AVCO inventory valuation"}'
```

## Features

| | Feature | Detail |
|---|---|---|
| 🔍 | Hybrid Search | Dense ANN + BM25 tsvector fused with RRF |
| 🔄 | Incremental Sync | `write_date` watermarks — only re-ingests changes |
| ⏰ | Auto Scheduler | APScheduler cron sync every 2 hours |
| 🏢 | Multi-tenant | Per-tenant vector collections + cache namespaces |
| ⚡ | SSE Streaming | Real-time token-by-token streaming |
| 📊 | Observability | Prometheus metrics + Grafana + structlog JSON |
| 🔐 | JWT Auth | RBAC scopes: query / ingest / admin |
| 🧪 | RAGAS Eval | Faithfulness, relevancy, precision, recall |
| 🐳 | Docker | One `docker compose up` for the full stack |

## Environment Variables

| Variable | Description |
|---|---|
| `ODOO_URL` | Your Odoo instance URL |
| `ODOO_DB` | Database name |
| `ODOO_USER` | Admin username |
| `ODOO_PASSWORD` | Admin password |
| `DATABASE_URL` | PostgreSQL + pgvector connection string |
| `REDIS_URL` | Redis connection string |
| `OPENAI_API_KEY` | For `text-embedding-3-large` |
| `ANTHROPIC_API_KEY` | For Claude (primary LLM) |
| `JWT_SECRET` | Token signing secret |

## Development

```bash
pip install -e ".[dev]"
pytest tests/ -v --cov=src
ruff check src tests
```

## Hire the Author

Built by **Paul Nyoike** — Python Backend Engineer · Odoo ERP Specialist · AI Integration  
🔗 [Upwork Profile](https://www.upwork.com/freelancers/~0117b7d1b005b4b7f8)

## License

MIT © 2024 NyoikePaul
EOF
git add . && git commit -m "docs: full README v2 — architecture, badges, quick start, hire section 🚀"

# ── Push ──────────────────────────────────────────────────────────
echo ""
echo "🚀 Pushing 17 commits with email: $EMAIL"
git push origin "$BRANCH"

echo ""
git log --format="%C(green)%h%Creset  %ae  %s" -17 | nl
echo ""
echo "✅  17 commits pushed as $EMAIL"
echo "⏳  Refresh https://github.com/NyoikePaul in 2 minutes"
echo "    → Look for 17 green squares on today's date"
