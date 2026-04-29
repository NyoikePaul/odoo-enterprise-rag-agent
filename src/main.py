from fastapi import FastAPI

app = FastAPI()


from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
import os

app.mount("/static", StaticFiles(directory="src/static"), name="static")

class ChatRequest(BaseModel):
    query: str

@app.post("/chat")
async def chat(req: ChatRequest):
    # TODO: replace with your real RAG agent call
    return {"response": f"Echo: {req.query}"}


@app.get("/chat")
def chat_ui():
    return FileResponse(os.path.join("src/static", "chat.html"))

