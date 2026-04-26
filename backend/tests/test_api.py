"""
Backend API tests — uses SQLite in-memory (no PostgreSQL needed in CI).
Run: cd backend && pytest tests/ -v --cov=app
"""
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.main import app
from app.core.database import get_db, Base

SQLALCHEMY_TEST_URL = "sqlite:///./test.db"
engine_test = create_engine(
    SQLALCHEMY_TEST_URL,
    connect_args={"check_same_thread": False}
)
TestingSession = sessionmaker(autocommit=False, autoflush=False, bind=engine_test)


def override_get_db():
    db = TestingSession()
    try:
        yield db
    finally:
        db.close()


app.dependency_overrides[get_db] = override_get_db


@pytest.fixture(scope="session", autouse=True)
def setup_db():
    Base.metadata.create_all(bind=engine_test)
    yield
    Base.metadata.drop_all(bind=engine_test)
    import os
    if os.path.exists("test.db"):
        os.remove("test.db")


@pytest.fixture
def client():
    return TestClient(app)


# ── Health tests
class TestHealth:
    def test_root(self, client):
        r = client.get("/")
        assert r.status_code == 200
        assert r.json()["service"] == "TaskFlow API"

    def test_health(self, client):
        r = client.get("/api/health")
        assert r.status_code == 200
        assert "status" in r.json()

    def test_liveness(self, client):
        r = client.get("/api/health/live")
        assert r.status_code == 200
        assert r.json()["status"] == "alive"


# ── User tests
class TestUsers:
    def test_create_user(self, client):
        r = client.post("/api/users/", json={
            "email": "test@taskflow.io",
            "username": "testuser",
            "full_name": "Test User",
            "password": "secure123",
        })
        assert r.status_code == 201
        data = r.json()
        assert data["email"] == "test@taskflow.io"
        assert data["username"] == "testuser"
        assert "id" in data
        # Password must not be returned
        assert "password" not in data
        assert "hashed_pw" not in data

    def test_duplicate_email_rejected(self, client):
        payload = {"email": "dup@taskflow.io", "username": "dup1",
                   "full_name": "Dup", "password": "x"}
        client.post("/api/users/", json=payload)
        r = client.post("/api/users/", json={**payload, "username": "dup2"})
        assert r.status_code == 400

    def test_list_users(self, client):
        r = client.get("/api/users/")
        assert r.status_code == 200
        assert isinstance(r.json(), list)

    def test_get_user_not_found(self, client):
        r = client.get("/api/users/99999")
        assert r.status_code == 404


# ── Task tests
class TestTasks:
    @pytest.fixture
    def user_id(self, client):
        r = client.post("/api/users/", json={
            "email": "taskowner@taskflow.io",
            "username": "taskowner",
            "full_name": "Task Owner",
            "password": "pw123",
        })
        return r.json()["id"]

    def test_create_task(self, client, user_id):
        r = client.post("/api/tasks/", json={
            "title":    "Set up EKS cluster",
            "priority": "high",
            "status":   "todo",
            "owner_id": user_id,
        })
        assert r.status_code == 201
        data = r.json()
        assert data["title"]    == "Set up EKS cluster"
        assert data["priority"] == "high"
        assert data["status"]   == "todo"

    def test_stats_before_tasks(self, client):
        r = client.get("/api/tasks/stats")
        assert r.status_code == 200
        data = r.json()
        assert "total" in data
        assert "done" in data
        assert "in_progress" in data

    def test_list_tasks(self, client):
        r = client.get("/api/tasks/")
        assert r.status_code == 200
        assert isinstance(r.json(), list)

    def test_filter_by_status(self, client, user_id):
        client.post("/api/tasks/", json={
            "title": "Done task", "status": "done",
            "priority": "low", "owner_id": user_id
        })
        r = client.get("/api/tasks/?status=done")
        assert r.status_code == 200
        assert all(t["status"] == "done" for t in r.json())

    def test_update_task(self, client, user_id):
        create = client.post("/api/tasks/", json={
            "title": "Old title", "status": "todo",
            "priority": "low", "owner_id": user_id
        })
        tid = create.json()["id"]
        r = client.put(f"/api/tasks/{tid}", json={"status": "done"})
        assert r.status_code == 200
        assert r.json()["status"] == "done"

    def test_delete_task(self, client, user_id):
        create = client.post("/api/tasks/", json={
            "title": "Delete me", "status": "todo",
            "priority": "low", "owner_id": user_id
        })
        tid = create.json()["id"]
        r = client.delete(f"/api/tasks/{tid}")
        assert r.status_code == 204
        assert client.get(f"/api/tasks/{tid}").status_code == 404

    def test_stats_route_not_matched_as_task_id(self, client):
        """
        Verifies /api/tasks/stats is handled as the stats endpoint,
        not as /{task_id} with task_id='stats' (which would give 422).
        """
        r = client.get("/api/tasks/stats")
        assert r.status_code == 200
        assert "total" in r.json()
