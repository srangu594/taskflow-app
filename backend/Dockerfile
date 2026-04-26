# ── Stage 1: Install dependencies
FROM python:3.12-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Stage 2: Runtime image (minimal)
FROM python:3.12-slim
WORKDIR /app

# Security: create non-root user
RUN groupadd -r appuser && useradd -r -g appuser -s /sbin/nologin appuser

# Copy installed packages from builder stage
COPY --from=builder /install /usr/local

# Copy application source
COPY . .

# Fix ownership before switching user
RUN chown -R appuser:appuser /app

USER appuser

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

EXPOSE 8000

# Liveness check — used by Docker Compose health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/api/health/live')"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "2", "--proxy-headers", "--forwarded-allow-ips", "*"]
