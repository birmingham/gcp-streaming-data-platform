FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

ENV PYTHONUNBUFFERED=1

# MODE selects the role at container-run time: "producer" or "consumer".
# Same image, two deployments — set MODE (and the other env vars below)
# per-deployment rather than building separate images.
ENTRYPOINT ["python", "app/main.py"]
