from fastapi import FastAPI, Depends, Query
from src.application.services.odoo_context_builder import OdooContextBuilder
from src.presentation.dependencies.services import get_context_builder

app = FastAPI(
    title="Odoo Enterprise RAG Agent",
    description="High-performance AI Gateway for ERP Grounding",
    version="1.0.0"
)

@app.get("/health")
def health_check():
    return {"status": "online", "engine": "FastAPI 0.100+", "integration": "Odoo XML-RPC"}

@app.post("/api/v1/chat")
async def chat_with_context(
    user_query: str,
    email: str = Query(..., description="Customer email for Odoo lookup"),
    context_builder: OdooContextBuilder = Depends(get_context_builder)
):
    """
    Simulates a RAG flow where ERP data is retrieved before hitting the LLM.
    """
    # Step 1: Get ERP Context
    erp_context = context_builder.get_customer_insights(email)
    
    # Step 2: In a full RAG, you'd send erp_context + user_query to the LLM
    # For now, we return the retrieved context to prove the plumbing works.
    return {
        "query": user_query,
        "retrieved_erp_context": erp_context,
        "agent_status": "Ready for LLM synthesis"
    }
