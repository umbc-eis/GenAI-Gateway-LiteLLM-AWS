FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# --timeout-keep-alive must exceed the ALB idle_timeout (160s) so the ALB never
# reuses a keep-alive connection that uvicorn has already closed (avoids sporadic 502s).
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "3000", "--workers", "4", "--timeout-keep-alive", "165"]