import xmlrpc.client
from typing import List, Dict, Any
from src.config import settings

class OdooClient:
    """Senior-level XML-RPC Client with authenticated session handling."""
    
    def __init__(self):
        self.url = settings.ODOO_URL
        self.db = settings.ODOO_DB
        self.username = settings.ODOO_USER
        self.password = settings.ODOO_PASSWORD
        self._uid = None

    @property
    def uid(self):
        if not self._uid:
            try:
                common = xmlrpc.client.ServerProxy(f"{self.url}/xmlrpc/2/common")
                self._uid = common.authenticate(self.db, self.username, self.password, {})
            except Exception as e:
                print(f"Failed to authenticate with Odoo: {e}")
                return None
        return self._uid

    def search_read(self, model: str, domain: List, fields: List) -> List[Dict[str, Any]]:
        if not self.uid:
            return []
        models = xmlrpc.client.ServerProxy(f"{self.url}/xmlrpc/2/object")
        return models.execute_kw(
            self.db, self.uid, self.password,
            model, 'search_read', [domain], {'fields': fields}
        )
