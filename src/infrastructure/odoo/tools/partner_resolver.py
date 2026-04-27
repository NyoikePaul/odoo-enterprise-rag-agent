from langchain.tools import tool
from src.infrastructure.odoo.xmlrpc_client import odoo_client

@tool
def get_customer_financial_summary(partner_id: int):
    """
    Retrieves the financial status of a partner by ID.
    Returns total due, credit limits, and contact info.
    """
    try:
        fields = ['name', 'total_due', 'credit_limit', 'email', 'phone']
        result = odoo_client.execute_kw('res.partner', 'read', [[partner_id]], {'fields': fields})
        return result[0] if result else "Partner not found."
    except Exception as e:
        return f"Error fetching data: {str(e)}"
