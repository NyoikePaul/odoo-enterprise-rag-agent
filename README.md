# Odoo Enterprise RAG Agent

This agent uses LangChain and GPT-4 to interact with Odoo ERP data and a local knowledge base.

## 🏗️ System Architecture

\`\`\`mermaid
graph TD
    A[User Query] --> B[FastAPI Gateway]
    B --> C{Agent Reasoning}
    C --> D[pgvector: Knowledge Base Search]
    C --> E[Odoo ERP: Live Data via XML-RPC]
    D --> F[Context Synthesis]
    E --> F
    F --> G[LLM Response / Ticket Resolution]
\`\`\`

## 🚀 Getting Started
- Python 3.10+
- PostgreSQL with pgvector
- Odoo 16.0+ (Enterprise or Community)
