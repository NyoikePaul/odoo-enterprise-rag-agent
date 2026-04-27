from src.infrastructure.odoo.xmlrpc_client import OdooClient
from src.application.services.odoo_context_builder import OdooContextBuilder

def get_odoo_client() -> OdooClient:
    return OdooClient()

def get_context_builder() -> OdooContextBuilder:
    # Injecting the infrastructure into the application service
    client = get_odoo_client()
    return OdooContextBuilder(client)
