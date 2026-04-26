from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from sqlalchemy import text
from app.core.database import get_db
from datetime import datetime

router = APIRouter()


@router.get("/health")
def health_check(db: Session = Depends(get_db)):
    try:
        db.execute(text("SELECT 1"))
        db_status = "healthy"
    except Exception as e:
        db_status = f"unhealthy: {str(e)}"
    return {
        "status":    "ok" if db_status == "healthy" else "degraded",
        "timestamp": datetime.utcnow().isoformat(),
        "version":   "1.0.0",
        "database":  db_status,
    }


@router.get("/health/live")
def liveness():
    """Kubernetes liveness probe — is the process running?"""
    return {"status": "alive"}


@router.get("/health/ready")
def readiness(db: Session = Depends(get_db)):
    """Kubernetes readiness probe — is the app ready for traffic?"""
    try:
        db.execute(text("SELECT 1"))
        return {"status": "ready"}
    except Exception:
        from fastapi import Response
        return Response(
            status_code=503,
            content='{"status":"not ready"}',
            media_type="application/json"
        )
