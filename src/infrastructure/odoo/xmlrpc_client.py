import xmlrpc.client
import os

class OdooClient:
    def __init__(self):
        self.url = os.getenv("ODOO_URL")
        self.db = os.getenv("ODOO_DB")
        self.username = os.getenv("ODOO_EMAIL")
        self.password = os.getenv("ODOO_API_KEY")
        self.common = xmlrpc.client.ServerProxy(f"{self.url}/xmlrpc/2/common")
        self.uid = self.common.authenticate(self.db, self.username, self.password, {})
        self.models = xmlrpc.client.ServerProxy(f"{self.url}/xmlrpc/2/object")

    def execute_kw(self, model, method, args, kwargs=None):
        kwargs = kwargs or {}
        return self.models.execute_kw(self.db, self.uid, self.password, model, method, args, kwargs)

odoo_client = OdooClient()
