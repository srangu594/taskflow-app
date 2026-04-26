from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
import uvicorn
import os
import logging
from datetime import datetime

from app.core.database import engine
from app.models import models
from app.api import health, users, tasks

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Auto-create tables on startup (Alembic handles migrations in production)
models.Base.metadata.create_all(bind=engine)

app = FastAPI(
    title="TaskFlow API",
    description="3-Tier Task Management Application",
    version="1.0.0",
    docs_url="/api/docs",
    redoc_url="/api/redoc",
)

app.add_middleware(GZipMiddleware, minimum_size=1000)
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("ALLOWED_ORIGINS", "*").split(","),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Router registration — prefixes match nginx proxy and K8s ingress paths
app.include_router(health.router, prefix="/api",       tags=["Health"])
app.include_router(users.router,  prefix="/api/users", tags=["Users"])
app.include_router(tasks.router,  prefix="/api/tasks", tags=["Tasks"])


@app.get("/")
def root():
    return {
        "service":   "TaskFlow API",
        "version":   "1.0.0",
        "status":    "running",
        "timestamp": datetime.utcnow().isoformat(),
    }


if __name__ == "__main__":
    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=8000,
        reload=False,
        workers=2,
    )
