# Нейроревью через n8n

Этот workflow настраивает n8n как HTTP-сервис для автоматического нейроревью кода. Он не создаёт Jira-задачи и не обновляет Confluence: на вход получает GitHub pull request webhook, diff или ссылку на GitHub pull request, запускает LLM-проверку и возвращает JSON-отчёт с Markdown-версией результата.

## Что делает workflow

1. Принимает `POST` webhook `/webhook/speedsters-neuroreview`.
2. Валидирует `WEBHOOK_TOKEN`, тип события и входные данные.
3. Если пришёл GitHub `pull_request` webhook, обрабатывает action `opened`, `reopened`, `synchronize` или `ready_for_review`.
4. Если передан `diff` или `patch`, ревьюит его напрямую.
5. Если передан `pullRequestUrl`, `diffUrl` или GitHub PR payload, скачивает `.diff`.
6. Исключает шумные или сгенерированные артефакты, включая Markdown-доки, lock-файлы и экспорт `n8n/neuroreview.workflow.json`.
7. Делит большой diff на чанки.
8. Отправляет чанки в выбранную LLM через OpenRouter или OpenAI.
9. Объединяет findings, удаляет дубли, сортирует по severity и ограничивает итоговый список самыми важными замечаниями.
10. Если это GitHub PR webhook и задан `GIT_TOKEN`, публикует Markdown-отчёт комментарием в PR.
11. Возвращает JSON с полями `summary`, `findings`, `markdown` и `commentPosted`.

## Запуск n8n

Подготовьте env-файл:

```bash
cp n8n/.env.example n8n/.env
```

Заполните `OPENROUTER_API_KEY` и `WEBHOOK_TOKEN` в `n8n/.env`. Для приватных GitHub PR и публикации результата комментарием в PR укажите `GIT_TOKEN` с правом чтения pull request и записи issue comments.

По умолчанию workflow настроен на OpenRouter и бесплатную модель `openai/gpt-oss-20b:free`:

```dotenv
LLM_PROVIDER=openrouter
OPENROUTER_API_KEY=sk-or-...
OPENROUTER_MODEL=openai/gpt-oss-20b:free
PUBLIC_N8N_URL=https://ejhdvds.ru/
WEBHOOK_TOKEN=<random-token>
```

`WEBHOOK_TOKEN` добавляется в GitHub webhook URL как query-параметр и проверяется workflow перед запуском LLM. Не коммитьте `n8n/.env`; для ротации токена замените значение и обновите URL webhook в GitHub.

Бесплатные модели OpenRouter стоят `0`, но API всё равно требует ключ OpenRouter. Если нужен OpenAI fallback, укажите:

```dotenv
LLM_PROVIDER=openai
OPENAI_API_KEY=sk-...
OPENAI_MODEL=gpt-5.4-nano
```

Для локального импорта workflow с ключом из `n8n/.env` и запуска контейнера:

```bash
n8n/import-local-workflow.sh
```

Запуск через Docker Compose, если workflow уже импортирован в n8n:

```bash
cd n8n
docker compose up -d
```

Если `docker compose` недоступен, можно запустить напрямую:

```bash
docker run -d \
  --name speedsters-n8n \
  --restart unless-stopped \
  -p 127.0.0.1:5678:5678 \
  --env-file n8n/.env \
  -e N8N_HOST=0.0.0.0 \
  -e N8N_PORT=5678 \
  -e N8N_PROTOCOL=http \
  -e N8N_SECURE_COOKIE=false \
  -e N8N_RUNNERS_ENABLED=false \
  -e N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true \
  -e N8N_BLOCK_ENV_ACCESS_IN_NODE=true \
  -e GENERIC_TIMEZONE=Etc/UTC \
  -v "$PWD/n8n/n8n_data:/home/node/.n8n" \
  -v "$PWD/n8n/neuroreview.workflow.json:/workflows/neuroreview.workflow.json:ro" \
  n8nio/n8n:1.91.3
```

После старта откройте n8n:

- http://localhost:5678

Импортируйте workflow:

- файл: `n8n/neuroreview.workflow.json`
- workflow name: `Speedsters Neuroreview`

Активируйте workflow в UI n8n.

## GitHub webhook

В настройках GitHub repository добавьте webhook:

- Payload URL: `https://ejhdvds.ru/public/webhook/speedsters-neuroreview?token=<WEBHOOK_TOKEN>`
- Content type: `application/json`
- Events: `Pull requests`

Сам n8n должен быть доступен только локально или во внутренней Docker-сети. Публичным оставляйте только reverse-proxy endpoint с `WEBHOOK_TOKEN`.

Workflow запускает нейроревью для action:

- `opened` - PR выставлен;
- `reopened` - PR переоткрыт;
- `synchronize` - в PR добавлены новые commits;
- `ready_for_review` - draft PR переведён в review.

Для локальной проверки вместо GitHub можно отправить payload с заголовком `X-GitHub-Event: pull_request`.

Комментарий нейроревью всегда формируется на русском языке. По умолчанию workflow публикует только самые важные замечания: `quick` - до 1, `standard` - до 3, `strict` - до 5. Если в ревью есть `critical` или `high`, `low`-замечания скрываются.

Для GitHub PR webhook workflow дополнительно ограничивает объём diff, отправляемый в LLM: берёт короткий фрагмент каждого релевантного файла и максимум два чанка. Это нужно, чтобы бесплатная модель не зависала на больших документационных или экспортных изменениях.

## Формат запроса

Вариант с inline diff:

```json
{
  "repository": "Speedsters",
  "reviewMode": "standard",
  "diff": "diff --git a/README.md b/README.md\n..."
}
```

Вариант с GitHub PR:

```json
{
  "repository": "Speedsters",
  "pullRequestUrl": "https://github.com/org/repo/pull/123",
  "reviewMode": "standard"
}
```

Вариант с GitHub pull request webhook:

```json
{
  "action": "opened",
  "repository": {
    "full_name": "org/repo"
  },
  "pull_request": {
    "html_url": "https://github.com/org/repo/pull/123",
    "diff_url": "https://github.com/org/repo/pull/123.diff",
    "comments_url": "https://api.github.com/repos/org/repo/issues/123/comments",
    "title": "SCRUM-11 add neuroreview"
  }
}
```

Поддерживаемые `reviewMode`:

- `quick` - более крупные чанки, быстрее и дешевле; используется по умолчанию для GitHub PR webhook;
- `standard` - баланс скорости и качества;
- `strict` - меньшие чанки, больше внимания к деталям.

## Пример вызова

```bash
curl -sS http://localhost:5678/webhook/speedsters-neuroreview \
  -H 'Content-Type: application/json' \
  -d @payload.json
```

## Формат ответа

```json
{
  "ok": true,
  "repository": "Speedsters",
  "reviewMode": "standard",
  "trigger": "github_pull_request",
  "commentPosted": true,
  "chunksReviewed": 2,
  "summary": "Найдено замечаний: 1. Critical: 0, high: 1, medium: 0, low: 0.",
  "findings": [
    {
      "severity": "high",
      "file": "src/api/review.ts",
      "line": 42,
      "title": "Необработанная ошибка внешнего API",
      "description": "При таймауте запрос завершится без понятного статуса.",
      "recommendation": "Добавить retry с ограничением и явный failure status."
    }
  ],
  "markdown": "# Neuroreview: Speedsters\n..."
}
```

## Ограничения

- Workflow сейчас поддерживает inline diff/patch и GitHub PR URL.
- Для GitLab/Bitbucket нужно добавить отдельный нормализатор URL и API fetch.
- Workflow публикует результат в GitHub PR comment только для GitHub `pull_request` webhook и только если задан `GIT_TOKEN`. Для ручных вызовов вызывающая система может взять `markdown` или `findings` из ответа.
- Runtime-проверка LLM требует рабочий ключ выбранного провайдера: `OPENROUTER_API_KEY` или `OPENAI_API_KEY`.
