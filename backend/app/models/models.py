from sqlalchemy import Column, Integer, String, Boolean, DateTime, ForeignKey, Enum, Text
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from app.core.database import Base
import enum


class PriorityEnum(str, enum.Enum):
    low    = "low"
    medium = "medium"
    high   = "high"


class StatusEnum(str, enum.Enum):
    todo        = "todo"
    in_progress = "in_progress"
    done        = "done"


class User(Base):
    __tablename__ = "users"

    id         = Column(Integer, primary_key=True, index=True)
    email      = Column(String(255), unique=True, index=True, nullable=False)
    username   = Column(String(100), unique=True, index=True, nullable=False)
    full_name  = Column(String(255), nullable=False)
    hashed_pw  = Column(String(255), nullable=False)
    is_active  = Column(Boolean, default=True)
    avatar_url = Column(String(500), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())

    tasks = relationship("Task", back_populates="owner", cascade="all, delete-orphan")


class Task(Base):
    __tablename__ = "tasks"

    id          = Column(Integer, primary_key=True, index=True)
    title       = Column(String(300), nullable=False)
    description = Column(Text, nullable=True)
    status      = Column(Enum(StatusEnum), default=StatusEnum.todo, nullable=False)
    priority    = Column(Enum(PriorityEnum), default=PriorityEnum.medium, nullable=False)
    due_date    = Column(DateTime(timezone=True), nullable=True)
    tags        = Column(String(500), nullable=True)
    owner_id    = Column(Integer, ForeignKey("users.id"), nullable=False)
    created_at  = Column(DateTime(timezone=True), server_default=func.now())
    updated_at  = Column(DateTime(timezone=True), onupdate=func.now())

    owner = relationship("User", back_populates="tasks")
