FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /srv
COPY app.py .
RUN useradd --system --uid 10001 runner
USER runner
CMD ["python", "app.py"]
