
## 🏗️ Technical Highlights
- **Stateful Grounding**: The agent fetches live Odoo partner and invoice data to reduce LLM "hallucinations" regarding customer accounts.
- **Asynchronous Scalability**: Built on FastAPI's `async/await` pattern to handle concurrent webhook callbacks from M-Pesa or ERP triggers.
- **Security First**: Implements a non-root Docker execution environment and Pydantic-based secret management.
- **Observability**: Structured logging ready for ELK/Grafana integration.
