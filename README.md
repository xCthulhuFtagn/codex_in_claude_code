# OpenAI/Codex в Claude Code через LiteLLM

Эта инструкция запускает публичную OpenAI-модель внутри агентного окружения Claude Code:

```text
Claude Code -> Anthropic Messages API -> LiteLLM -> OpenAI Responses API
```

В результате Claude Code отвечает за системный prompt, разрешения, tools, plan mode, subagents и работу с файлами, а генерацию выполняет OpenAI-модель. Текущая сессия Codex, её память и внутренний harness при этом не переносятся.

> Anthropic официально не поддерживает запуск Claude Code на non-Claude моделях. Схема технически работает через совместимый gateway, но после обновления Claude Code или LiteLLM её следует заново проверять.

## Что понадобится

- Linux или macOS с `bash`/`zsh`;
- Claude Code 2.1.129 или новее;
- `uv`;
- для рекомендуемого варианта — OpenAI API key с отдельным API-биллингом;
- для Варианта B — `git` (нужен для сборки локально патченого LiteLLM, см. ниже);
- свободный локальный порт `4000`.

В текущем окружении уже установлены Claude Code `2.1.206` и `uv`.

## Вариант A: OpenAI API key — рекомендуемый

### 1. Установить LiteLLM

На 10 июля 2026 года используется зафиксированный подписанный стабильный релиз, чтобы обновление адаптера не сломало tool calls или streaming неожиданно:

```bash
uv tool install 'litellm[proxy]==1.91.1'
litellm --version
```

Перед будущим обновлением сверяйте номер с подписанным GitHub release. Не используйте для постоянной установки `main-latest` или неприкреплённую версию.

Не устанавливайте скомпрометированные версии `1.82.7` и `1.82.8`. Если одна из них когда-либо запускалась, переустановки недостаточно: необходимо ротировать все секреты, доступные тому процессу.

### 2. Создать конфигурацию

Создайте рядом с этим README файл `litellm.yaml`:

```yaml
model_list:
  - model_name: openai-coder
    model_info:
      mode: responses
    litellm_params:
      model: openai/gpt-5.3-codex
      api_key: os.environ/OPENAI_API_KEY

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

Здесь:

- `openai-coder` — локальное имя модели, которое увидит Claude Code;
- `openai/gpt-5.3-codex` — реальная OpenAI-модель;
- `mode: responses` явно фиксирует OpenAI Responses API;
- `LITELLM_MASTER_KEY` защищает локальный gateway от запросов без авторизации.

Для более универсальной, но обычно более дорогой модели замените `openai/gpt-5.3-codex` на `openai/gpt-5.5`.

### 3. Задать секреты

В первом терминале:

```bash
export OPENAI_API_KEY='sk-ВАШ_OPENAI_API_KEY'
export LITELLM_MASTER_KEY="sk-local-$(openssl rand -hex 24)"

printf 'Сохраните ключ gateway для второго терминала: %s\n' "$LITELLM_MASTER_KEY"
```

Не записывайте `OPENAI_API_KEY` в `litellm.yaml`, README, git или project-level `.claude/settings.json`.

### 4. Запустить gateway

Из каталога с `litellm.yaml`:

```bash
litellm \
  --config "$PWD/litellm.yaml" \
  --host 127.0.0.1 \
  --port 4000
```

Ожидаемый адрес:

```text
http://127.0.0.1:4000
```

Привязка к `127.0.0.1` важна: proxy с provider key не должен быть доступен из локальной сети или интернета.

Не используйте `--detailed_debug` при работе с реальным кодом: подробные логи могут содержать prompts, исходники и другие чувствительные данные.

### 5. Проверить gateway и `/v1/messages`

Во втором терминале подставьте сохранённое значение `LITELLM_MASTER_KEY`:

```bash
export LITELLM_MASTER_KEY='sk-local-ЗНАЧЕНИЕ_ИЗ_ПЕРВОГО_ТЕРМИНАЛА'

curl -fsS \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://127.0.0.1:4000/health/readiness

curl -fsS \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://127.0.0.1:4000/v1/models
```

В `/v1/models` должна присутствовать запись `openai-coder`. Затем проверьте Anthropic Messages endpoint и streaming:

```bash
curl -N http://127.0.0.1:4000/v1/messages \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'anthropic-version: 2023-06-01' \
  -H 'content-type: application/json' \
  -d '{
    "model": "openai-coder",
    "max_tokens": 64,
    "stream": true,
    "messages": [
      {"role": "user", "content": "Reply exactly OK"}
    ]
  }'
```

Успешный ответ приходит как последовательность SSE-событий и заканчивается событием завершения. Если proxy сначала собирает весь ответ и только затем печатает его, Claude Code будет зависать — streaming должен быть настоящим.

### 6. Направить Claude Code в LiteLLM

В том же втором терминале:

```bash
unset OPENAI_API_KEY
unset ANTHROPIC_API_KEY
unset CLAUDE_CODE_OAUTH_TOKEN

export ANTHROPIC_BASE_URL='http://127.0.0.1:4000'
export ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY"

export ANTHROPIC_MODEL='openai-coder'
export ANTHROPIC_DEFAULT_FABLE_MODEL='openai-coder'
export ANTHROPIC_DEFAULT_OPUS_MODEL='openai-coder'
export ANTHROPIC_DEFAULT_SONNET_MODEL='openai-coder'
export ANTHROPIC_DEFAULT_HAIKU_MODEL='openai-coder'
export CLAUDE_CODE_SUBAGENT_MODEL='openai-coder'

claude --model openai-coder
```

Все model-переменные заданы намеренно. Claude Code может использовать отдельные модели для основного диалога, фоновых операций и subagents; без явного mapping часть запросов уйдёт с Anthropic model ID, которого нет в конфигурации LiteLLM.

`CLAUDE_CODE_SUBAGENT_MODEL` принудительно направляет все subagents в `openai-coder`. Если нужна отдельная дешёвая модель для subagents, уберите эту переменную и добавьте отдельный alias в `model_list`.

`ANTHROPIC_BASE_URL` указывается без `/v1`: Claude Code сам обращается к `/v1/messages`.

### 7. Добавить модель в `/model`

Gateway discovery не показывает `gpt-*` и `openai-*`: Claude Code принимает из `/v1/models` только ID, начинающиеся с `claude` или `anthropic`. Для ручной записи в picker используйте:

```bash
export ANTHROPIC_CUSTOM_MODEL_OPTION='openai-coder'
export ANTHROPIC_CUSTOM_MODEL_OPTION_NAME='GPT-5.3-Codex via LiteLLM'
export ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION='OpenAI Responses API through local LiteLLM'
```

Либо продолжайте запускать Claude Code с `--model openai-coder`.

## Обязательная проверка tool calls

Текстовый ответ ещё не доказывает, что агентный цикл работает. Проверьте хотя бы один реальный tool call:

```bash
claude -p \
  --model openai-coder \
  --allowedTools Bash \
  'Use Bash to run pwd, then return the exact path.'
```

Затем в тестовом git-репозитории проверьте полный цикл:

1. попросите прочитать файл;
2. попросите изменить одну строку;
3. проверьте diff;
4. попросите запустить тест;
5. запустите subagent или команду, которая его использует.

После каждого обновления Claude Code или LiteLLM повторяйте этот smoke test.

## Постоянный launcher

Не обязательно экспортировать переменные глобально. Безопаснее создать личный файл вне репозитория, например `~/.config/claude-code/openai-via-litellm.env`, выдать ему права `600` и подключать только перед запуском нужной сессии:

```bash
mkdir -p ~/.config/claude-code
touch ~/.config/claude-code/openai-via-litellm.env
chmod 600 ~/.config/claude-code/openai-via-litellm.env
```

Содержимое файла:

```bash
unset OPENAI_API_KEY
unset ANTHROPIC_API_KEY
unset CLAUDE_CODE_OAUTH_TOKEN
export LITELLM_MASTER_KEY='sk-local-ВАШ_КЛЮЧ_GATEWAY'
export ANTHROPIC_BASE_URL='http://127.0.0.1:4000'
export ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY"
export ANTHROPIC_MODEL='openai-coder'
export ANTHROPIC_DEFAULT_FABLE_MODEL='openai-coder'
export ANTHROPIC_DEFAULT_OPUS_MODEL='openai-coder'
export ANTHROPIC_DEFAULT_SONNET_MODEL='openai-coder'
export ANTHROPIC_DEFAULT_HAIKU_MODEL='openai-coder'
export CLAUDE_CODE_SUBAGENT_MODEL='openai-coder'
```

Запуск:

```bash
source ~/.config/claude-code/openai-via-litellm.env
claude --model openai-coder
```

`OPENAI_API_KEY` нужен только процессу LiteLLM. Не передавайте его Claude Code.

## Вариант B: ChatGPT Pro/Max OAuth — экспериментальный, требует локального патча LiteLLM

LiteLLM также документирует provider `chatgpt/`, который выполняет OAuth device flow и обращается к ChatGPT subscription backend (тот же backend, что использует официальный Codex CLI). Это не официальный способ интеграции Claude Code ни со стороны OpenAI, ни со стороны Anthropic. Он может перестать работать, вернуть Cloudflare `403` или измениться без предупреждения.

**Важно (проверено 2026-07-13 на LiteLLM 1.91.1 и 1.92.0):** заводской пакет `litellm[proxy]` не работает с реальными сессиями Claude Code через `chatgpt/` provider — ловит два независимых бага при первом же tool call. Рабочих смерженных фиксов в апстриме на эту дату нет (см. ниже), поэтому нужен локально патченый билд. Используйте этот вариант только если готовы поддерживать свой форк и перепроверять его после каждого обновления LiteLLM.

### Известные баги `chatgpt/` provider

1. **`ChatgptException - {"detail":"System messages are not allowed"}`** (400 при любом реальном запросе Claude Code).
   Причина: `litellm/completion_extras/litellm_responses_transformation/transformation.py`, функция `convert_chat_completion_messages_to_responses_api`. Если `system`-сообщение приходит как список content-блоков (именно так Claude Code шлёт system, с `cache_control`), код не мержит его в `instructions`, а кладёт как есть — `role: "system"` item прямо в `input`. ChatGPT/Codex backend такие item'ы отклоняет. Со строковым `system` (`"system": "..."`) баг не проявляется — поэтому синтетические curl-тесты с простым system легко вводят в заблуждение, что всё работает.
2. **`ChatgptException - Unknown items in responses API response: []`** (500, стабильно воспроизводится, не флап).
   Причина: `litellm/responses/streaming_iterator.py`, класс `BaseResponsesAPIStreamingIterator`. ChatGPT/Codex backend в потоковом ответе шлёт финальное событие `response.completed` с пустым `output`, а реальный текст приходит раньше, в событиях `response.output_item.done` / `response.output_text.done`. Итератор эти события не накапливает, поэтому мост `completion()` → Responses API получает пустой `output` и падает.

На issue-трекере LiteLLM на попытки починить баг №1 было несколько PR (`#21493`, `#22967`, `#22968`, `#23511`, `#23698`, `#24997`) — все закрыты как abandoned/not-planned; смержен только `#21192`, но он не покрывает именно list-формат system в этом файле. Для бага №2 есть открытый, но не смерженный PR `#31332` (родственный issue `#25429`). Если однажды один из этих PR смержат в релиз — патч ниже, скорее всего, станет не нужен; перед обновлением LiteLLM стоит попробовать сначала заводской пакет.

### 1. Собрать патченую версию LiteLLM

Ставим `git`, если его нет, затем клонируем LiteLLM на том же зафиксированном теге, что и в Варианте A, в поддиректорию рядом с этим README:

```bash
cd "$(dirname "$0" 2>/dev/null || pwd)"   # каталог с этим README
git clone --branch v1.91.1 --depth 1 https://github.com/BerriAI/litellm.git litellm-fork
cd litellm-fork
git switch -c fix-chatgpt-claude-code
```

В `litellm-fork/litellm/completion_extras/litellm_responses_transformation/transformation.py` найдите в функции `convert_chat_completion_messages_to_responses_api` блок:

```python
            if role == "system":
                # Extract system message as instructions
                if isinstance(content, str):
                    if instructions:
                        # Concatenate multiple system prompts with a space
                        instructions = f"{instructions} {content}"
                    else:
                        instructions = content
                else:
                    input_items.append(
                        {
                            "type": "message",
                            "role": role,
                            "content": self._convert_content_to_responses_format(
                                content,  # type: ignore[arg-type]
                                role,  # type: ignore
                            ),
                        }
                    )
```

и вставьте перед последним `else` новую ветку для list-формата:

```python
                elif isinstance(content, list):
                    # List-format system content (e.g. Claude Code's cache-controlled
                    # content blocks) must also be merged into instructions instead of
                    # kept as a role=system input item: backends like ChatGPT/Codex
                    # reject role=system items inside "input".
                    text_parts = [
                        block.get("text", "")
                        for block in content
                        if isinstance(block, dict) and block.get("type") in ("text", "input_text")
                    ]
                    system_text = "\n".join(filter(None, text_parts))
                    if system_text:
                        instructions = f"{instructions} {system_text}" if instructions else system_text
```

В `litellm-fork/litellm/responses/streaming_iterator.py` внесите три правки:

```python
# 1. Импорт (рядом с "from litellm.responses.utils import ResponsesAPIRequestUtils"):
from litellm.responses.sse_output_recovery import (
    record_output_item_chunk,
    record_output_text_chunk,
)

# 2. В BaseResponsesAPIStreamingIterator.__init__, после self._stream_created_time = time.time():
self._streamed_output_items: Dict[int, Dict[str, Any]] = {}
self._streamed_text_only_items: Dict[int, Dict[str, Any]] = {}

# 3. В _process_chunk, сразу после строки
#    "openai_responses_api_chunk = self.responses_api_provider_config.transform_streaming_response(...)":
_raw_event_type = parsed_chunk.get("type")
if _raw_event_type == ResponsesAPIStreamEvents.OUTPUT_ITEM_DONE.value:
    record_output_item_chunk(
        parsed_chunk=parsed_chunk,
        output_items=self._streamed_output_items,
    )
elif _raw_event_type == ResponsesAPIStreamEvents.OUTPUT_TEXT_DONE.value:
    record_output_text_chunk(
        parsed_chunk=parsed_chunk,
        output_items=self._streamed_output_items,
        text_only_items=self._streamed_text_only_items,
    )
```

И там же, перед строкой `self.completed_response = openai_responses_api_chunk` (внутри блока, который проверяет `_chunk_type in (RESPONSE_COMPLETED, RESPONSE_INCOMPLETE, RESPONSE_FAILED)`), добавьте backfill пустого `output`:

```python
if _chunk_type != openai_types.ResponsesAPIStreamEvents.RESPONSE_FAILED:
    response_obj_for_backfill: Optional[Any] = getattr(openai_responses_api_chunk, "response", None)
    if response_obj_for_backfill is not None and not getattr(response_obj_for_backfill, "output", None):
        merged_items = {
            **self._streamed_text_only_items,
            **self._streamed_output_items,
        }
        if merged_items:
            response_obj_for_backfill.output = [
                item for _, item in sorted(merged_items.items())
            ]
```

Собрать и установить патченую версию поверх обычной (заменяет `litellm` в `uv tool` окружении):

```bash
cd ..   # обратно в каталог с этим README
uv tool install --force './litellm-fork[proxy]'
litellm --version   # всё ещё покажет 1.91.1 — это версия из pyproject, не признак отсутствия патча
```

### 2. Создать конфигурацию для `chatgpt/` provider

```yaml
model_list:
  - model_name: openai-coder
    model_info:
      mode: responses
    litellm_params:
      model: chatgpt/gpt-5.3-codex

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

`chatgpt/gpt-5.3-codex` — имя из документации LiteLLM, но backend может отклонить его для конкретного аккаунта (`"The 'gpt-5.3-codex' model is not supported when using Codex with a ChatGPT account"`), если подписка даёт доступ к другим моделям. Узнать реальное имя модели, которое видит ваш аккаунт: посмотрите `model` в `~/.codex/config.toml` (если установлен Codex CLI и вы в нём уже авторизованы) или раздел `[tui.model_availability_nux]` там же — и подставьте это имя вместо `gpt-5.3-codex`.

### 3. Подготовить каталог для OAuth-токенов и master key

```bash
mkdir -p ~/.config/litellm/chatgpt
chmod 700 ~/.config/litellm/chatgpt

export CHATGPT_TOKEN_DIR="$HOME/.config/litellm/chatgpt"
export LITELLM_MASTER_KEY="sk-local-$(openssl rand -hex 24)"
```

### 4. Запустить gateway и пройти device-flow авторизацию

```bash
litellm \
  --config "$PWD/litellm.yaml" \
  --host 127.0.0.1 \
  --port 4000
```

LiteLLM выведет verification URL и device code:

```text
Sign in with ChatGPT using device code:
1) Visit https://auth.openai.com/codex/device
2) Enter code: XXXX-XXXXX
```

Откройте именно `https://auth.openai.com/codex/device` (не обычный `chat.openai.com`), войдите в нужный ChatGPT-аккаунт, введите код и нажмите подтверждение/разрешить доступ. Код живёт недолго — если не успели, увидите ту же строку в логе при следующей проверке, но код не обновится сам. Если код истёк:

```bash
pkill -9 -f "litellm --config $PWD/litellm.yaml"
rm -f ~/.config/litellm/chatgpt/auth.json   # иначе LiteLLM переиспользует протухший device_code_requested_at и не запросит новый код
# затем запустить litellm заново командой выше
```

После успешного входа токены (access/refresh/id token, account_id) сохранятся в `CHATGPT_TOKEN_DIR/auth.json`; не добавляйте этот каталог в репозиторий или общий backup. При последующих запусках повторный вход не нужен, пока refresh token валиден.

### 5. Проверить gateway

```bash
curl -fsS -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://127.0.0.1:4000/health/readiness
curl -fsS -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://127.0.0.1:4000/v1/models
```

Если оба curl возвращают `502` при том, что gateway точно поднят и слушает `127.0.0.1:4000` — проверьте, не настроен ли в окружении `http_proxy`/`https_proxy`: некоторые локальные/песочные окружения проксируют даже запросы на `127.0.0.1`. Добавьте `--noproxy '*'` к curl для диагностики, а для самого Claude Code и для `curl` в дальнейшем — `export NO_PROXY='127.0.0.1,localhost'` (и `no_proxy` в нижнем регистре, некоторые клиенты чувствительны к регистру).

Затем — тест с `system` в list-формате (именно так, а не строкой, Claude Code шлёт system; это отличает реальную проверку от синтетической, которая может не поймать баг №1):

```bash
curl -sS http://127.0.0.1:4000/v1/messages \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'anthropic-version: 2023-06-01' \
  -H 'content-type: application/json' \
  -d '{
    "model": "openai-coder",
    "max_tokens": 64,
    "system": [{"type": "text", "text": "You are a helpful assistant."}],
    "messages": [{"role": "user", "content": "Reply exactly OK"}]
  }'
```

Ожидаемый ответ — обычное Anthropic-сообщение с `"text":"OK"`. Если вместо этого `System messages are not allowed` или `Unknown items in responses API response` — патч не применился или не переустановился (`uv tool install --force` из каталога `litellm-fork`).

### 6. Направить Claude Code в gateway

Переменные — те же, что в Варианте A (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL` и остальные `ANTHROPIC_DEFAULT_*_MODEL`/`CLAUDE_CODE_SUBAGENT_MODEL`, все указывают на `openai-coder`). Если пришлось выставлять `NO_PROXY` на шаге 5, добавьте его и сюда — иначе сам Claude Code будет получать `502` от того же прокси.

### 7. Постоянный launcher

Как и в Варианте A, удобнее не экспортировать переменные глобально, а держать их в отдельном файле с правами `600`, например `~/.config/claude-code/openai-via-litellm.env`:

```bash
unset OPENAI_API_KEY
unset ANTHROPIC_API_KEY
unset CLAUDE_CODE_OAUTH_TOKEN
export LITELLM_MASTER_KEY='sk-local-ВАШ_КЛЮЧ_GATEWAY'
export ANTHROPIC_BASE_URL='http://127.0.0.1:4000'
export ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY"
export NO_PROXY='127.0.0.1,localhost'
export no_proxy="$NO_PROXY"
export ANTHROPIC_MODEL='openai-coder'
export ANTHROPIC_DEFAULT_FABLE_MODEL='openai-coder'
export ANTHROPIC_DEFAULT_OPUS_MODEL='openai-coder'
export ANTHROPIC_DEFAULT_SONNET_MODEL='openai-coder'
export ANTHROPIC_DEFAULT_HAIKU_MODEL='openai-coder'
export CLAUDE_CODE_SUBAGENT_MODEL='openai-coder'
```

И отдельный скрипт для перезапуска gateway (`start-gateway.sh` рядом с `litellm.yaml`), переиспользующий тот же launcher-файл для `LITELLM_MASTER_KEY`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

source ~/.config/claude-code/openai-via-litellm.env
export CHATGPT_TOKEN_DIR="$HOME/.config/litellm/chatgpt"

exec litellm \
  --config "$PWD/litellm.yaml" \
  --host 127.0.0.1 \
  --port 4000
```

Запуск:

```bash
source ~/.config/claude-code/openai-via-litellm.env
claude --model openai-coder
```

ChatGPT backend отвергает некоторые поля публичного API, включая token limits и `metadata`; LiteLLM удаляет их для этого provider. Поэтому ограничение длины ответа и часть семантики могут отличаться от варианта с OpenAI API key.

Обязательно прогоните проверку из раздела «Обязательная проверка tool calls» ниже — именно на ней ловятся оба бага выше, синтетический `curl` без реального Claude Code их может не показать. Если маршрут не работает стабильно, переходите на официальный OpenAI API key; не копируйте вручную OAuth-токены из `~/.codex` или браузера.

## Диагностика

### Claude Code открывает обычный Anthropic login

Проверьте, что задан именно gateway credential:

```bash
test -n "$ANTHROPIC_AUTH_TOKEN" && echo 'token set'
printf '%s\n' "$ANTHROPIC_BASE_URL"
```

Одного `ANTHROPIC_BASE_URL` недостаточно: сохранённый Claude login может остаться активным. Не печатайте само значение token.

### `401 Unauthorized`

- `ANTHROPIC_AUTH_TOKEN` должен совпадать с `LITELLM_MASTER_KEY` процесса proxy;
- после изменения ключа перезапустите LiteLLM;
- не используйте OpenAI API key как gateway token;
- убедитесь, что запрос не уходит в другой процесс на порту `4000`.

### `404` на `/v1/messages`

- `ANTHROPIC_BASE_URL` должен быть `http://127.0.0.1:4000`, без `/v1`;
- проверьте, что запущен LiteLLM Proxy, а не только Python SDK;
- выполните curl-тест из раздела выше.

### `Model ... not found`

- в Claude Code используйте `openai-coder`, то есть значение `model_name`, а не `openai/gpt-5.3-codex`;
- проверьте все `ANTHROPIC_DEFAULT_*_MODEL` и `CLAUDE_CODE_SUBAGENT_MODEL`;
- перезапустите Claude Code после изменения environment variables.

### Модель отсутствует в `/model`

Это ожидаемо для ID без префикса `claude`/`anthropic`. Используйте:

```bash
claude --model openai-coder
```

или `ANTHROPIC_CUSTOM_MODEL_OPTION` из раздела выше.

### `400` с `output_config`, `context_management`, `thinking` или beta tool fields

Сначала:

1. убедитесь, что установлена ровно документированная версия LiteLLM;
2. проверьте `model_info.mode: responses`;
3. повторите минимальный curl-тест;
4. посмотрите тело upstream-ошибки в терминале LiteLLM.

Не включайте глобальный `drop_params: true` как первое решение: он способен скрыть несовместимость, молча удалив новый параметр Claude Code.

Как временную диагностику, а не постоянное решение, можно отключить экспериментальные Claude Code fields:

```bash
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
```

Если ошибка связана именно с adaptive thinking:

```bash
export CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1
```

Эти переключатели уменьшают возможности harness. Правильное долгосрочное решение — обновить или исправить adapter и вернуть функции обратно.

### Ответ появляется целиком после долгой паузы

Gateway или внешний reverse proxy буферизует SSE. Для локальной схемы обращайтесь к LiteLLM напрямую через `127.0.0.1:4000`. Если используется nginx, ingress или корпоративный gateway, отключите response buffering для `/v1/messages`.

### Обычный текст работает, а tools — нет

- запустите smoke test с `Bash`;
- проверьте JSON аргументов tool call в логах LiteLLM;
- временно отключите сторонние MCP-серверы и повторите тест только со встроенным tool;
- проверьте issue tracker LiteLLM для используемых версий Claude Code и OpenAI-модели.

### `ChatgptException - System messages are not allowed` (только Вариант B)

Это баг №1 из раздела «Известные баги `chatgpt/` provider» в Варианте B: list-формат `system` (именно так его шлёт Claude Code) утекает как `role: system` item в `input` вместо `instructions`. Проверьте:

- что установлен именно патченый `litellm-fork`, а не заводской пакет: `uv tool install --force './litellm-fork[proxy]'` из каталога с этим README;
- curl-тест с `"system": [{"type": "text", "text": "..."}]` (list, не строка) из раздела Варианта B — со строковым `system` баг не проявляется, и тест ничего не покажет;
- что патч в `convert_chat_completion_messages_to_responses_api` (`litellm/completion_extras/litellm_responses_transformation/transformation.py`) действительно применён — откройте файл и убедитесь, что там есть ветка `elif isinstance(content, list):`.

### `ChatgptException - Unknown items in responses API response: []` (только Вариант B)

Это баг №2 из раздела «Известные баги `chatgpt/` provider» в Варианте B: при стриминге ChatGPT/Codex backend шлёт `response.completed` с пустым `output`, а `BaseResponsesAPIStreamingIterator` не подхватывает предшествующие `response.output_item.done`/`response.output_text.done`. Ошибка стабильно воспроизводится (не флап) и повторяется на каждой попытке (`LiteLLM Retried: N times` в логе). Проверьте, что патч в `litellm/responses/streaming_iterator.py` применён (наличие `self._streamed_output_items` в `__init__`) и что `litellm-fork` установлен, а не заводской пакет.

## Остановка и удаление

Остановить proxy: `Ctrl+C` в его терминале.

Очистить переменные текущего shell:

```bash
unset OPENAI_API_KEY LITELLM_MASTER_KEY CHATGPT_TOKEN_DIR
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
unset ANTHROPIC_DEFAULT_FABLE_MODEL
unset ANTHROPIC_DEFAULT_OPUS_MODEL
unset ANTHROPIC_DEFAULT_SONNET_MODEL
unset ANTHROPIC_DEFAULT_HAIKU_MODEL
unset ANTHROPIC_CUSTOM_MODEL_OPTION
unset ANTHROPIC_CUSTOM_MODEL_OPTION_NAME
unset ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION
unset CLAUDE_CODE_SUBAGENT_MODEL
unset CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS
unset CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING
unset NO_PROXY no_proxy
```

Удалить установленный tool:

```bash
uv tool uninstall litellm
```

Если ставили Вариант B с локальным патчем: `uv tool uninstall litellm` удаляет и патченую версию — независимо от того, была она установлена из PyPI или из `./litellm-fork`. Каталог `litellm-fork` при этом не трогается; удалите его вручную (`rm -rf litellm-fork`), если он больше не нужен, либо оставьте — тогда `uv tool install --force './litellm-fork[proxy]'` снова поднимет патченую версию без повторного клонирования. Чтобы вернуться на заводской пакет без патча, переустановите зафиксированную версию из PyPI: `uv tool install --force 'litellm[proxy]==1.91.1'`.

Если использовался экспериментальный ChatGPT OAuth route, удаление `CHATGPT_TOKEN_DIR` разлогинит только LiteLLM. Перед удалением убедитесь, что путь указывает именно на отдельный каталог LiteLLM, а не на `~/.codex`.

## Источники

- [Claude Code: другие LLM gateways](https://code.claude.com/docs/en/llm-gateway)
- [Claude Code: gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol)
- [Claude Code: model configuration](https://code.claude.com/docs/en/model-config)
- [LiteLLM: Claude Code с non-Anthropic моделями](https://docs.litellm.ai/docs/tutorials/claude_non_anthropic_models)
- [LiteLLM: mapping `/v1/messages` в OpenAI Responses API](https://docs.litellm.ai/docs/anthropic_unified/messages_to_responses_mapping)
- [LiteLLM: ChatGPT subscription provider](https://docs.litellm.ai/docs/providers/chatgpt)
- [LiteLLM v1.91.1](https://github.com/BerriAI/litellm/releases/tag/v1.91.1)
- [Инцидент с LiteLLM 1.82.7/1.82.8](https://github.com/BerriAI/litellm/issues/24518)
- [OpenAI: GPT-5.3-Codex](https://developers.openai.com/api/docs/models/gpt-5.3-codex)
