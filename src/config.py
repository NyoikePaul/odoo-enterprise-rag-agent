from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    # Odoo Configuration
    ODOO_URL: str = "https://your-odoo-instance.com"
    ODOO_DB: str = "production"
    ODOO_USER: str = "admin"
    ODOO_PASSWORD: str = "secret"
    
    # AI & Vector DB
    OPENAI_API_KEY: str = "sk-..."
    DATABASE_URL: str = "postgresql://ai_admin:secretpassword@localhost:5432/rag_knowledge_base"
    
    class Config:
        env_file = ".env"

settings = Settings()
