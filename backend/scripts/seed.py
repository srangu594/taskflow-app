"""
Database seed script — loads demo users and tasks.

Usage:
  Docker Compose : docker exec taskflow-backend python scripts/seed.py
  Kubernetes     : kubectl exec -n taskflow deploy/taskflow-backend -- python scripts/seed.py

The script is idempotent — it skips if data already exists.
"""
import sys
import os

# Works from /app (container) and from backend/ (local)
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault(
    "DATABASE_URL",
    "postgresql://taskflow:taskflow123@postgres:5432/taskflow_db"
)

from passlib.context import CryptContext
from app.core.database import SessionLocal, engine
from app.models.models import Base, User, Task, PriorityEnum, StatusEnum

pwd_ctx = CryptContext(schemes=["bcrypt"], deprecated="auto")

# Create tables (safe if they already exist)
Base.metadata.create_all(bind=engine)

db = SessionLocal()
try:
    if db.query(User).count() > 0:
        print("Database already seeded — skipping.")
        sys.exit(0)

    users = [
        User(email="sandy@taskflow.io",  username="sandy",
             full_name="Sandy Rangu",    hashed_pw=pwd_ctx.hash("password123"), is_active=True),
        User(email="alex@taskflow.io",   username="alex",
             full_name="Alex DevOps",    hashed_pw=pwd_ctx.hash("password123"), is_active=True),
        User(email="priya@taskflow.io",  username="priya",
             full_name="Priya Sharma",   hashed_pw=pwd_ctx.hash("password123"), is_active=True),
    ]
    db.add_all(users)
    db.commit()
    for u in users:
        db.refresh(u)

    tasks = [
        Task(title="Set up EKS cluster with Terraform",
             description="3 AZ cluster: On-Demand system node + Spot app nodes via dual node groups",
             status=StatusEnum.done,        priority=PriorityEnum.high,   owner_id=users[0].id),
        Task(title="Configure Jenkins 9-stage pipeline",
             description="checkout→lint→test→build→push ECR→tf plan→update manifest→ArgoCD sync→smoke",
             status=StatusEnum.in_progress, priority=PriorityEnum.high,   owner_id=users[0].id),
        Task(title="Build FastAPI backend with PostgreSQL",
             description="3-tier: React 18 → FastAPI → RDS PostgreSQL, full CRUD, health probes",
             status=StatusEnum.done,        priority=PriorityEnum.high,   owner_id=users[1].id),
        Task(title="Configure ArgoCD GitOps sync",
             description="ArgoCD Application watching k8s/base — auto-prune + self-heal enabled",
             status=StatusEnum.todo,        priority=PriorityEnum.medium, owner_id=users[1].id),
        Task(title="Set up Prometheus + Grafana monitoring",
             description="kube-prometheus-stack via Helm, ServiceMonitor, PrometheusRules, dashboards",
             status=StatusEnum.in_progress, priority=PriorityEnum.medium, owner_id=users[2].id),
        Task(title="Configure AWS RDS PostgreSQL Single-AZ",
             description="db.t3.medium, 7-day PITR, Performance Insights, enhanced monitoring, gp3",
             status=StatusEnum.done,        priority=PriorityEnum.high,   owner_id=users[0].id),
        Task(title="Set up GitHub Actions CI + CD workflows",
             description="ci.yml: PR quality gate — cd.yml: build→ECR→S3→EKS→smoke on merge to main",
             status=StatusEnum.todo,        priority=PriorityEnum.medium, owner_id=users[2].id),
        Task(title="Configure HPA for backend pods",
             description="min=2, max=8 replicas — scale on CPU 70% + memory 80%",
             status=StatusEnum.done,        priority=PriorityEnum.low,    owner_id=users[1].id),
        Task(title="Implement session.sh start/stop workflow",
             description="One-command start (~25min) and stop (~15min) for weekly sessions",
             status=StatusEnum.done,        priority=PriorityEnum.medium, owner_id=users[0].id),
        Task(title="Write incident runbook for on-call",
             description="OOMKilled, CrashLoopBackOff, DB connection refused, Spot interruption",
             status=StatusEnum.todo,        priority=PriorityEnum.low,    owner_id=users[2].id),
    ]
    db.add_all(tasks)
    db.commit()
    print(f"Seeded {len(users)} users and {len(tasks)} tasks successfully.")

finally:
    db.close()
