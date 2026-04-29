from src.agents.odoo_agent import get_odoo_agent
import os

# Initialize agent
agent_executor = get_odoo_agent()

# Test query (Replace 1 with a real Partner ID from your Odoo)
response = agent_executor.invoke({"input": "What is the financial summary for partner ID 1?"})
print(response["output"])
