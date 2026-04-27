# Speedsters

## Документация

- [Нейроревью через n8n в Confluence](https://speedsters.atlassian.net/wiki/spaces/Speedsters/pages/7897217/n8n)
- [Настройка нейроревью через n8n](docs/n8n_neuroreview.md)
- [Workflow для импорта в n8n](n8n/neuroreview.workflow.json)

## Быстрый запуск n8n

```bash
cp n8n/.env.example n8n/.env
# заполните OPENROUTER_API_KEY и WEBHOOK_TOKEN в n8n/.env
n8n/import-local-workflow.sh
```

По умолчанию используется бесплатная модель `openai/gpt-oss-20b:free` через OpenRouter. Для OpenAI fallback переключите `LLM_PROVIDER=openai` и заполните `OPENAI_API_KEY`.

Для автоматического запуска при выставлении PR добавьте в GitHub webhook на `POST /public/webhook/speedsters-neuroreview?token=<WEBHOOK_TOKEN>` с событием `Pull requests`. Подробности: [Настройка нейроревью через n8n](docs/n8n_neuroreview.md).
