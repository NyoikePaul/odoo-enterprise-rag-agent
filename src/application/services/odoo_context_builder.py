from src.infrastructure.odoo.xmlrpc_client import OdooClient

class OdooContextBuilder:
    """Expert-level service to bridge ERP data into LLM prompts."""
    
    def __init__(self, odoo_client: OdooClient):
        self.client = odoo_client

    def get_customer_insights(self, email: str) -> str:
        """Fetch partner data and recent transactions to ground the AI response."""
        partners = self.client.search_read(
            'res.partner', 
            [('email', '=', email)], 
            ['name', 'total_invoiced', 'credit']
        )
        
        if not partners:
            return "No matching customer found in Odoo records."
        
        p = partners[0]
        return f"Customer {p['name']} has a lifetime value of {p['total_invoiced']} and current credit of {p['credit']}."
