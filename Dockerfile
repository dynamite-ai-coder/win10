FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PORT=10000 \
    HOME=/home/app

RUN useradd --create-home --shell /bin/bash --user-group app \
    && mkdir -p /home/app/.ssh \
    && chmod 0700 /home/app/.ssh \
    && chown -R app:app /home/app

WORKDIR /app
COPY app.py ./

USER app
EXPOSE 10000
CMD ["python3", "app.py"]
