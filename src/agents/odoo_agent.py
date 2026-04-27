from langchain_openai import ChatOpenAI
from langchain.agents import AgentExecutor, create_openai_functions_agent
from langchain_core.prompts import ChatPromptTemplate, MessagesPlaceholder
from src.infrastructure.odoo.tools.partner_resolver import get_customer_financial_summary

def get_odoo_agent():
    llm = ChatOpenAI(model="gpt-4-turbo-preview", temperature=0)
    tools = [get_customer_financial_summary]

    prompt = ChatPromptTemplate.from_messages([
        ("system", "You are an expert Odoo Support Agent. Use tools to look up live ERP data before answering."),
        ("human", "{input}"),
        MessagesPlaceholder(variable_name="agent_scratchpad"),
    ])

    agent = create_openai_functions_agent(llm, tools, prompt)
    return AgentExecutor(agent=agent, tools=tools, verbose=True)
