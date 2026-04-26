from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from typing import List
from passlib.context import CryptContext

from app.core.database import get_db
from app.models.models import User
from app.models.schemas import UserCreate, UserOut, UserUpdate

router  = APIRouter()
pwd_ctx = CryptContext(schemes=["bcrypt"], deprecated="auto")


def hash_password(pw: str) -> str:
    return pwd_ctx.hash(pw)


@router.post("/", response_model=UserOut, status_code=201)
def create_user(user: UserCreate, db: Session = Depends(get_db)):
    if db.query(User).filter(User.email == user.email).first():
        raise HTTPException(status_code=400, detail="Email already registered")
    if db.query(User).filter(User.username == user.username).first():
        raise HTTPException(status_code=400, detail="Username already taken")
    db_user = User(
        email     = user.email,
        username  = user.username,
        full_name = user.full_name,
        hashed_pw = hash_password(user.password),
    )
    db.add(db_user)
    db.commit()
    db.refresh(db_user)
    return db_user


@router.get("/", response_model=List[UserOut])
def list_users(skip: int = 0, limit: int = 50, db: Session = Depends(get_db)):
    return db.query(User).offset(skip).limit(limit).all()


@router.get("/{user_id}", response_model=UserOut)
def get_user(user_id: int, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return user


@router.put("/{user_id}", response_model=UserOut)
def update_user(user_id: int, payload: UserUpdate, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    for k, v in payload.model_dump(exclude_unset=True).items():
        setattr(user, k, v)
    db.commit()
    db.refresh(user)
    return user


@router.delete("/{user_id}", status_code=204)
def delete_user(user_id: int, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    db.delete(user)
    db.commit()
