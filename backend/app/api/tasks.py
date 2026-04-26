from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from typing import List, Optional

from app.core.database import get_db
from app.models.models import Task, User, StatusEnum, PriorityEnum
from app.models.schemas import TaskCreate, TaskOut, TaskUpdate

router = APIRouter()


@router.post("/", response_model=TaskOut, status_code=201)
def create_task(task: TaskCreate, db: Session = Depends(get_db)):
    owner = db.query(User).filter(User.id == task.owner_id).first()
    if not owner:
        raise HTTPException(status_code=404, detail="Owner user not found")
    db_task = Task(**task.model_dump())
    db.add(db_task)
    db.commit()
    db.refresh(db_task)
    return db_task


@router.get("/", response_model=List[TaskOut])
def list_tasks(
    skip:     int = 0,
    limit:    int = 100,
    status:   Optional[StatusEnum]   = Query(None),
    priority: Optional[PriorityEnum] = Query(None),
    owner_id: Optional[int]          = Query(None),
    db: Session = Depends(get_db),
):
    q = db.query(Task)
    if status:   q = q.filter(Task.status   == status)
    if priority: q = q.filter(Task.priority == priority)
    if owner_id: q = q.filter(Task.owner_id == owner_id)
    return q.order_by(Task.created_at.desc()).offset(skip).limit(limit).all()


# NOTE: /stats MUST be declared before /{task_id}
# If /{task_id} comes first, FastAPI matches "stats" as a task_id integer
# and returns a 422 Unprocessable Entity error.
@router.get("/stats")
def get_stats(db: Session = Depends(get_db)):
    return {
        "total":        db.query(Task).count(),
        "todo":         db.query(Task).filter(Task.status == StatusEnum.todo).count(),
        "in_progress":  db.query(Task).filter(Task.status == StatusEnum.in_progress).count(),
        "done":         db.query(Task).filter(Task.status == StatusEnum.done).count(),
        "high_priority":db.query(Task).filter(Task.priority == PriorityEnum.high).count(),
    }


@router.get("/{task_id}", response_model=TaskOut)
def get_task(task_id: int, db: Session = Depends(get_db)):
    task = db.query(Task).filter(Task.id == task_id).first()
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    return task


@router.put("/{task_id}", response_model=TaskOut)
def update_task(task_id: int, payload: TaskUpdate, db: Session = Depends(get_db)):
    task = db.query(Task).filter(Task.id == task_id).first()
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    for k, v in payload.model_dump(exclude_unset=True).items():
        setattr(task, k, v)
    db.commit()
    db.refresh(task)
    return task


@router.delete("/{task_id}", status_code=204)
def delete_task(task_id: int, db: Session = Depends(get_db)):
    task = db.query(Task).filter(Task.id == task_id).first()
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    db.delete(task)
    db.commit()
