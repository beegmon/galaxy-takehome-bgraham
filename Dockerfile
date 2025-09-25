# syntax=docker/dockerfile:1.7
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8000 \
    WORKERS=2 \
    THREADS=4

# Non-root user
RUN addgroup --system --gid 1000 app && adduser --system --uid 1000 --ingroup app app

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --upgrade pip && pip install -r requirements.txt

COPY app.py ./

EXPOSE 8000

USER app

CMD ["sh", "-c", "exec gunicorn --bind 0.0.0.0:${PORT} --workers ${WORKERS} --threads ${THREADS} --timeout 60 --access-logfile - app:app"]
