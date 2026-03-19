FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py models.py store.py simulator.py ./
COPY static/ ./static/
COPY templates/ ./templates/

EXPOSE 8892

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8892"]
