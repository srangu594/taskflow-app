from pydantic import BaseModel, EmailStr
from typing import Optional
from datetime import datetime
from app.models.models import PriorityEnum, StatusEnum


# ── User schemas
class UserBase(BaseModel):
    email:     EmailStr
    username:  str
    full_name: str


class UserCreate(UserBase):
    password: str


class UserUpdate(BaseModel):
    full_name:  Optional[str] = None
    avatar_url: Optional[str] = None


class UserOut(UserBase):
    id:         int
    is_active:  bool
    avatar_url: Optional[str] = None
    created_at: datetime

    class Config:
        from_attributes = True


# ── Task schemas
class TaskBase(BaseModel):
    title:       str
    description: Optional[str]       = None
    status:      StatusEnum          = StatusEnum.todo
    priority:    PriorityEnum        = PriorityEnum.medium
    due_date:    Optional[datetime]  = None
    tags:        Optional[str]       = None


class TaskCreate(TaskBase):
    owner_id: int


class TaskUpdate(BaseModel):
    title:       Optional[str]          = None
    description: Optional[str]          = None
    status:      Optional[StatusEnum]   = None
    priority:    Optional[PriorityEnum] = None
    due_date:    Optional[datetime]     = None
    tags:        Optional[str]          = None


class TaskOut(TaskBase):
    id:         int
    owner_id:   int
    created_at: datetime
    updated_at: Optional[datetime] = None
    owner:      UserOut

    class Config:
        from_attributes = True
